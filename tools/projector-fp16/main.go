// projector-fp16 reproduces the Veri 1 projector from its pinned upstream GGUF.
package main

import (
	"crypto/sha256"
	_ "embed"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
)

const (
	sourceSHA256 = "8882e9ddab3186f9aa71b1417c847177913e1466655ac944cf86e9b846735d62"
	resultSHA256 = "d4b5d02d6560745e18d74e84b1cceadf6736bc9b923293aebe14eb43a761c513"
)

//go:embed veri1-projector-layout.json
var recipeJSON []byte

type layout struct {
	SourceDataOffset int64      `json:"source_data_offset"`
	OutputHeader     []byte     `json:"output_header"`
	BF16Ranges       [][2]int64 `json:"bf16_ranges"`
}

func half(bits uint16) uint16 {
	sign := bits & 0x8000
	exponent := int((bits >> 7) & 0xff)
	fraction := bits & 0x7f
	switch {
	case exponent == 255 && fraction != 0:
		return sign | 0x7e00
	case exponent >= 143:
		return sign | 0x7c00
	case exponent >= 113:
		return sign | uint16(exponent-112)<<10 | fraction<<3
	case exponent < 102:
		return sign
	}
	// Round subnormals to nearest, ties to even.
	significand := uint16(128) + fraction
	if exponent >= 110 {
		return sign | significand<<uint(exponent-110)
	}
	shift := uint(110 - exponent)
	rounded := significand >> shift
	remainder := significand & ((1 << shift) - 1)
	midpoint := uint16(1) << (shift - 1)
	if remainder > midpoint || (remainder == midpoint && rounded&1 == 1) {
		rounded++
	}
	return sign | rounded
}

func convert(input, output string) error {
	var recipe layout
	if err := json.Unmarshal(recipeJSON, &recipe); err != nil {
		return err
	}
	source, err := os.Open(input)
	if err != nil {
		return err
	}
	defer source.Close()
	sourceHash := sha256.New()
	if _, err := io.Copy(sourceHash, source); err != nil {
		return err
	}
	if hex.EncodeToString(sourceHash.Sum(nil)) != sourceSHA256 {
		return fmt.Errorf("input does not match the pinned Hugging Face BF16 projector")
	}
	if _, err := source.Seek(recipe.SourceDataOffset, io.SeekStart); err != nil {
		return err
	}
	result, err := os.OpenFile(output, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0644)
	if err != nil {
		return err
	}
	verified := false
	defer func() {
		result.Close()
		if !verified {
			os.Remove(output)
		}
	}()

	resultHash := sha256.New()
	writer := io.MultiWriter(result, resultHash)
	if _, err := writer.Write(recipe.OutputHeader); err != nil {
		return err
	}
	var lookup [65536]uint16
	for i := range lookup {
		lookup[i] = half(uint16(i))
	}
	buffer := make([]byte, 4*1024*1024)
	var offset int64
	for _, span := range recipe.BF16Ranges {
		start, length := span[0], span[1]
		if start < offset || length <= 0 || length%2 != 0 {
			return fmt.Errorf("invalid BF16 tensor range at %d", start)
		}
		if _, err := io.CopyN(writer, source, start-offset); err != nil {
			return err
		}
		for remaining := length; remaining > 0; {
			block := buffer[:min(remaining, int64(len(buffer)))]
			if _, err := io.ReadFull(source, block); err != nil {
				return err
			}
			for index := 0; index < len(block); index += 2 {
				word := binary.LittleEndian.Uint16(block[index:])
				binary.LittleEndian.PutUint16(block[index:], lookup[word])
			}
			if _, err := writer.Write(block); err != nil {
				return err
			}
			remaining -= int64(len(block))
		}
		offset = start + length
	}
	if _, err := io.Copy(writer, source); err != nil {
		return err
	}
	if err := result.Close(); err != nil {
		return err
	}
	if hex.EncodeToString(resultHash.Sum(nil)) != resultSHA256 {
		return fmt.Errorf("converted output differs from the Veri 1 FP16 projector")
	}
	verified = true
	return nil
}

func main() {
	if len(os.Args) != 3 {
		fmt.Fprintln(os.Stderr, "usage: projector-fp16 INPUT_BF16.gguf OUTPUT_FP16.gguf")
		os.Exit(2)
	}
	if err := convert(os.Args[1], os.Args[2]); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	fmt.Println("FP16 projector matches the Veri 1 SHA-256.")
}

package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/sgl-project/sglang-omni/Voxt/internal/asr"
	"github.com/sgl-project/sglang-omni/Voxt/internal/eval"
	"github.com/sgl-project/sglang-omni/Voxt/internal/omni"
)

type row struct {
	Clip        string            `json:"clip"`
	Set         string            `json:"set"`
	Variant     string            `json:"variant"`
	AudioMS     float64           `json:"audio_ms"`
	ElapsedMS   float64           `json:"elapsed_ms"`
	Reference   string            `json:"reference"`
	Text        string            `json:"text"`
	Language    string            `json:"language"`
	Score       eval.Score        `json:"score"`
	Terms       []string          `json:"terms,omitempty"`
	TermsFound  []string          `json:"terms_found,omitempty"`
	FinalEvents []json.RawMessage `json:"final_events"`
}

func run() error {
	binary := flag.String("binary", "", "path to the supervised ASR server")
	target := flag.String("target", "", "target model directory")
	draft := flag.String("draft", "", "draft model directory, empty for target-only")
	bits := flag.String("draft-bits", "4", "draft quantization bits")
	evalDir := flag.String("eval", "testdata/eval", "Voxt benchmark directory")
	only := flag.String("only", "", "one clip ID, or empty for all 31")
	flag.Parse()
	if *binary == "" || *target == "" {
		return fmt.Errorf("-binary and -target are required")
	}

	suite, err := eval.Load(*evalDir, true)
	if err != nil {
		return err
	}
	var finalEvents []json.RawMessage
	runtime := omni.NewRuntime(omni.Config{
		Binary:       *binary,
		Env:          []string{"OMNI_DFLASH_PROFILE=1"},
		IdleTimeout:  -1,
		StartTimeout: 120 * time.Second,
		Log: func(level, message string) {
			const prefix = "omni: benchmark_sse "
			if event, ok := strings.CutPrefix(message, prefix); ok {
				finalEvents = append(finalEvents, json.RawMessage(event))
			} else if level != "debug" {
				fmt.Fprintln(os.Stderr, message)
			}
		},
	})
	defer runtime.Close()
	// The client reads the bit count before constructing the child process.
	if err := os.Setenv("VOXTNEW_DRAFT_BITS", *bits); err != nil {
		return err
	}
	model, err := omni.NewASR(runtime, omni.ASRAccurate, *target)
	if err != nil {
		return err
	}
	model = model.WithDraft(*draft)
	output := json.NewEncoder(os.Stdout)
	write := func(clip eval.Clip, variant string, hints []string) error {
		finalEvents = nil
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Minute)
		defer cancel()
		start := time.Now()
		result, err := model.Transcribe(ctx, asr.FileRequest{
			Audio: clip.PCM, Format: "pcm", Lang: "zh", Hints: hints,
		})
		if err != nil {
			return fmt.Errorf("%s %s: %w", clip.ID, variant, err)
		}
		if len(finalEvents) == 0 {
			return fmt.Errorf("%s %s: no observed final event", clip.ID, variant)
		}
		return output.Encode(row{
			Clip: clip.ID, Set: clip.Set, Variant: variant,
			AudioMS:   float64(clip.Duration()) / float64(time.Millisecond),
			ElapsedMS: float64(time.Since(start)) / float64(time.Millisecond),
			Reference: clip.Text, Text: result.Text, Language: result.Lang,
			Score: eval.Compare(clip.Text, result.Text), Terms: clip.Terms,
			TermsFound: eval.TermsFound(clip.Terms, result.Text), FinalEvents: finalEvents,
		})
	}

	clips := suite.All()
	if len(clips) != 31 {
		return fmt.Errorf("Voxt benchmark has %d clips, want 31", len(clips))
	}
	if err := write(clips[0], "warmup", nil); err != nil {
		return err
	}
	found := false
	for _, clip := range clips {
		if *only != "" && clip.ID != *only {
			continue
		}
		found = true
		if err := write(clip, "main zh", suite.Dictionary); err != nil {
			return err
		}
		if clip.Set == "dict" {
			if err := write(clip, "no bias", nil); err != nil {
				return err
			}
		}
	}
	if !found {
		return fmt.Errorf("unknown clip ID: %s", *only)
	}
	return nil
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

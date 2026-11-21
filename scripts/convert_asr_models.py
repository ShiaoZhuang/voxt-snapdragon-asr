#!/usr/bin/env python3
"""Export the pinned ASR Draft and an unquantized F16 audio projector."""

import argparse
import hashlib
import json
from pathlib import Path
import struct
import tempfile

import gguf
import numpy as np


ROOT = Path(__file__).resolve().parents[1]
DRAFT_REPO = "wilsonzheng0327/Qwen3-ASR-1.7B-dflash"
TARGET_NAME = "Qwen3-ASR-1.7B-Q8_0.gguf"
MMPROJ_NAME = "mmproj-Qwen3-ASR-1.7B-bf16.gguf"


def check_hash(path, expected):
    with path.open("rb") as source:
        if hashlib.file_digest(source, "sha256").hexdigest() != expected:
            raise ValueError(f"SHA-256 mismatch: {path}")


def copy_fields(writer, reader, predicate):
    for key, field in reader.fields.items():
        if predicate(key):
            kind = field.types[0]
            subtype = field.types[1] if kind == gguf.GGUFValueType.ARRAY else None
            writer.add_key_value(key, field.contents(), kind, subtype)


def write_model(writer, output):
    if output.exists():
        raise FileExistsError(output)
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=output.parent) as staging:
        path = Path(staging) / "model.gguf"
        writer.write_header_to_file(path)
        writer.write_kv_data_to_file()
        writer.write_tensors_to_file()
        writer.close()
        path.rename(output)


def convert_projector(source, output, lock):
    check_hash(source, lock["gguf_probe"]["files"][MMPROJ_NAME])
    reader = gguf.GGUFReader(source)
    writer = gguf.GGUFWriter(None, "clip")
    copy_fields(writer, reader, lambda key: not key.startswith("GGUF.") and key not in {
        "general.architecture", "general.file_type", "general.quantization_version", "general.alignment",
    })
    writer.add_file_type(gguf.LlamaFileType.MOSTLY_F16)
    for tensor in reader.tensors:
        if tensor.tensor_type == gguf.GGMLQuantizationType.BF16:
            shape = tuple(int(size) for size in reversed(tensor.shape))
            values = gguf.dequantize(tensor.data, tensor.tensor_type).astype(np.float16)
            if not np.isfinite(values).all():
                raise ValueError(f"FP16 overflow in {tensor.name}")
            writer.add_tensor(tensor.name, values.reshape(shape))
        else:
            writer.add_tensor(tensor.name, tensor.data)
    write_model(writer, output)


def convert_draft(source, target_path, output, lock):
    for name, sha in lock["mlx_models"][DRAFT_REPO]["files"].items():
        check_hash(source / name, sha)
    check_hash(target_path, lock["gguf_probe"]["files"][TARGET_NAME])
    config = json.loads((source / "config.json").read_text())
    layer = config["transformer_layer_config"]
    target = gguf.GGUFReader(target_path)
    width = target.fields["qwen3vl.embedding_length"].contents()
    depth = target.fields["qwen3vl.block_count"].contents()
    vocab_size = len(target.fields["tokenizer.ggml.tokens"].data)
    layers = config["aux_hidden_state_layer_ids"]
    reduced_vocab = config["draft_vocab_size"]
    mask = config["mask_token_id"]
    if (layer["hidden_size"] != width or layer["vocab_size"] != vocab_size
        or not layers or layers != sorted(set(layers)) or not 0 <= layers[0] <= layers[-1] < depth
        or not 0 <= mask < vocab_size or not 0 < reduced_vocab <= vocab_size
        or config["block_size"] != 8 or config["sliding_window_non_causal"]
        or config["sample_from_anchor"]):
        raise ValueError("Draft config is incompatible with the pinned ASR target")

    writer = gguf.GGUFWriter(None, "dflash")
    writer.add_name("Qwen3-ASR 1.7B causal DFlash")
    writer.add_file_type(gguf.LlamaFileType.MOSTLY_BF16)
    writer.add_vocab_size(vocab_size)
    writer.add_embedding_length(width)
    writer.add_block_count(layer["num_hidden_layers"])
    writer.add_feed_forward_length(layer["intermediate_size"])
    writer.add_context_length(layer["max_position_embeddings"])
    writer.add_head_count(layer["num_attention_heads"])
    writer.add_head_count_kv(layer["num_key_value_heads"])
    writer.add_key_length(layer["head_dim"])
    writer.add_value_length(layer["head_dim"])
    writer.add_layer_norm_rms_eps(layer["rms_norm_eps"])
    writer.add_rope_dimension_count(layer["head_dim"])
    writer.add_rope_freq_base(layer["rope_parameters"]["rope_theta"])
    writer.add_rope_dimension_sections([layer["head_dim"] // 2, 0, 0, 0])
    writer.add_causal_attention(True)
    writer.add_block_size(config["block_size"])
    writer.add_target_layers(layers)
    copy_fields(writer, target, lambda key: key.startswith("tokenizer.ggml.") and key != "tokenizer.ggml.mask_token_id")
    writer.add_mask_token_id(mask)

    checkpoint = source / "model.safetensors"
    with checkpoint.open("rb") as file:
        header_bytes, = struct.unpack("<Q", file.read(8))
        tensors = json.loads(file.read(header_bytes))
    tensor_bytes = np.memmap(checkpoint, mode="r", offset=8 + header_bytes, dtype=np.uint8)
    expected_shapes = {
        "fc.weight": [width, width * len(layers)],
        "lm_head.weight": [reduced_vocab, width],
        "d2t": [reduced_vocab],
        "hidden_norm.weight": [width],
    }
    for name, shape in expected_shapes.items():
        if tensors[name]["shape"] != shape:
            raise ValueError(f"{name} shape mismatch")
    names = gguf.get_tensor_name_map(gguf.MODEL_ARCH.DFLASH, layer["num_hidden_layers"])
    for name, tensor in tensors.items():
        if name in {"__metadata__", "t2d"}:
            continue
        start, end = tensor["data_offsets"]
        if name == "d2t":
            if tensor["dtype"] != "I64":
                raise ValueError("d2t must contain I64 offsets")
            ids = tensor_bytes[start:end].view("<i8") + np.arange(reduced_vocab, dtype=np.int64)
            if np.any(ids < 0) or np.any(ids >= vocab_size) or np.unique(ids).size != reduced_vocab:
                raise ValueError("invalid draft-to-target ID mapping")
            writer.add_tensor("d2t", ids)
            continue
        mapped = names.get_name("model." + name, try_suffixes=(".weight",))
        if mapped is None or tensor["dtype"] != "BF16":
            raise ValueError(f"unsupported draft tensor: {name}")
        data = tensor_bytes[start:end].view("<u2").reshape(tensor["shape"])
        if data.ndim == 1:
            writer.add_tensor(mapped, (data.astype(np.uint32) << 16).view(np.float32))
        else:
            writer.add_tensor(mapped, data, raw_dtype=gguf.GGMLQuantizationType.BF16)
    write_model(writer, output)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="model", required=True)
    for name in ("projector", "draft"):
        sub = commands.add_parser(name)
        sub.add_argument("source", type=Path)
        sub.add_argument("output", type=Path)
        if name == "draft":
            sub.add_argument("--target", required=True, type=Path)
    args = parser.parse_args()
    lock = json.loads((ROOT / "sources.lock.json").read_text())
    if args.model == "projector":
        convert_projector(args.source, args.output, lock)
    else:
        convert_draft(args.source, args.target, args.output, lock)


if __name__ == "__main__":
    main()

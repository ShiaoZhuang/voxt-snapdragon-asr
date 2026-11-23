"""Check a captured Qwen3-ASR verification projection against its GGUF weights."""

import argparse
import json
from pathlib import Path

import gguf
import numpy as np


def read_capture(directory):
    manifest = json.loads((directory / "capture.json").read_text(encoding="utf-8"))
    if (manifest["layer"], manifest["dtype"], manifest["input_shape"], manifest["output_shape"]) != (
        0, "float32-le", [8, 2048], [8, 6144]
    ):
        raise ValueError("expected a layer-0 capture of one eight-position verification batch")
    x = np.fromfile(directory / "ffn_norm.f32", dtype="<f4").reshape(8, 2048)
    y = np.fromfile(directory / "ffn_up.f32", dtype="<f4").reshape(8, 6144)
    if not np.isfinite(x).all() or not np.isfinite(y).all():
        raise ValueError("capture contains nonfinite values")
    if not np.any(y):
        raise ValueError("captured FFN output is all zeros")
    return x, y


def load_weight(target):
    reader = gguf.GGUFReader(target)
    tensor = next((t for t in reader.tensors if t.name == "blk.0.ffn_up.weight"), None)
    if tensor is None or tuple(tensor.shape) != (2048, 6144) or tensor.tensor_type != gguf.GGMLQuantizationType.Q8_0:
        raise ValueError("expected the Target's [2048, 6144] Q8_0 FFN up weight")
    return gguf.dequantize(tensor.data, tensor.tensor_type)


def compare(actual, expected):
    error = actual.astype(np.float64) - expected
    return {
        "max_abs_error": float(np.abs(error).max()),
        "relative_l2_error": float(np.linalg.norm(error) / np.linalg.norm(expected)),
    }


def round_trip_symmetric(data, max_code, axis=None):
    scale = np.maximum(np.max(np.abs(data), axis=axis, keepdims=True) / max_code, np.finfo(np.float32).tiny)
    return np.clip(np.rint(data / scale), -max_code, max_code) * scale


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--capture", type=Path, required=True)
    parser.add_argument("--target", type=Path, required=True)
    args = parser.parse_args()
    x, expected = read_capture(args.capture)
    weight = load_weight(args.target)
    reference = compare(x @ weight.T, expected)
    reference_passed = reference["relative_l2_error"] <= 1e-5
    report = {"q8_0_dense": reference}
    # Signed symmetric codes can be offset to U16/U8 with no change to their real values.
    # The reported differences here are from re-encoding activations and weights, on CPU.
    if reference_passed:
        x_a16 = round_trip_symmetric(x, 32767)
        report["a16_u8_per_tensor"] = compare(x_a16 @ round_trip_symmetric(weight, 127).T, expected)
        report["a16_u8_per_output_channel"] = compare(x_a16 @ round_trip_symmetric(weight, 127, axis=1).T, expected)
    print(json.dumps(report, indent=2))
    if not reference_passed:
        raise SystemExit(1)


if __name__ == "__main__":
    main()

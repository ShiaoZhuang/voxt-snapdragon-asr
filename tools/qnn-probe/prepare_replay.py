"""Build a U16/U8 QDQ replay from a real DFlash verification projection."""

import argparse
import json
from pathlib import Path

import numpy as np

from compare_capture import compare, load_weight, read_capture, symmetric_codes
from projection import write_projection


def prepare(capture, target, output):
    activation, native = read_capture(capture)
    weight = load_weight(target)
    dense = activation @ weight.T

    x_codes, x_scale = symmetric_codes(activation, 32767)
    w_codes, w_scale = symmetric_codes(weight, 127, axis=1)
    x_scale = x_scale.reshape(())
    w_scale = w_scale.ravel()
    # Every product and partial sum of these integer codes is exact in float64.
    accumulator = x_codes.astype(np.float64) @ w_codes.astype(np.float64).T
    reencoded = accumulator * x_scale * w_scale
    # This diagnostic calibrates on a single captured batch, with output headroom.
    y_scale = np.array(np.max(np.abs(reencoded)) / 32000, dtype=np.float32)
    if not np.isfinite(y_scale) or y_scale <= 0:
        raise ValueError("invalid projection output scale")
    expected = (np.rint(reencoded / float(y_scale)) + 32768).astype(np.uint16)
    feed = (x_codes + 32768).astype(np.uint16)
    initializers = {
        "w_u8": (w_codes.T + 128).astype(np.uint8),
        "x_scale": x_scale,
        "w_scale": w_scale,
        "y_scale": y_scale,
        "x_zero": np.array(32768, dtype=np.uint16),
        "w_zero": np.full(w_scale.shape, 128, dtype=np.uint8),
        "y_zero": np.array(32768, dtype=np.uint16),
    }
    output.mkdir(parents=True, exist_ok=False)
    write_projection(output / "verify_projection.onnx", initializers)
    np.savez(output / "input_and_reference.npz", feed=feed, expected=expected)

    dequantized_expected = (expected.astype(np.int32) - 32768) * float(y_scale)
    report = {
        "dense_vs_native_capture": compare(dense, native),
        "qdq_vs_dense_q8_0": compare(dequantized_expected, dense),
        "qdq_vs_native_capture": compare(dequantized_expected, native),
        "activation_scale": float(x_scale),
        "output_scale": float(y_scale),
        "weight_scale_count": int(w_scale.size),
    }
    text = json.dumps(report, indent=2) + "\n"
    (output / "preparation.json").write_text(text, encoding="utf-8")
    print(text, end="")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--capture", type=Path, required=True)
    parser.add_argument("--target", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    prepare(args.capture, args.target, args.output)


if __name__ == "__main__":
    main()

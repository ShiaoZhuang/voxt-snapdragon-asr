"""Prepare layer-0 grouped-query attention replay from a real DFlash verification batch."""

import argparse
import json
from pathlib import Path

import numpy as np
from onnx import TensorProto, helper

from compare_capture import compare
from projection import save_onnx_graph


def load_attention(directory):
    manifest = json.loads((directory / "attention.json").read_text(encoding="utf-8"))

    def read(name):
        info = manifest[name]
        return np.fromfile(directory / info["file"], dtype=info["dtype"]).reshape(info["shape"])

    q, k, v, mask, actual = (read(name) for name in ("q", "k", "v", "mask", "attention_output"))
    if manifest["flash"]:
        actual = actual.swapaxes(1, 2)
    else:
        v = v.swapaxes(-1, -2)
    scale = float(manifest["scale"])
    if not np.isfinite(scale) or scale <= 0 or q.shape != (1, 16, 8, 128) or actual.shape != q.shape:
        raise ValueError(f"unexpected attention scale or shape: scale={scale}, Q={q.shape}, Y={actual.shape}")
    if k.shape != v.shape or k.shape != (1, 8, k.shape[2], 128) or mask.shape[:3] != (1, 1, 8):
        raise ValueError(f"unexpected K/V or causal mask shape: K={k.shape}, V={v.shape}, mask={mask.shape}")

    if not np.all((mask == 0) | np.isneginf(mask)):
        raise ValueError("expected the additive 0/-inf causal attention mask")
    allowed = mask[0, 0] == 0
    counts = np.count_nonzero(allowed, axis=1)
    if counts[0] <= 1 or np.any(np.diff(counts) != 1) or np.any(allowed[:-1] & ~allowed[1:]):
        raise ValueError(f"each candidate must add one visible cache slot: counts={counts.tolist()}")
    if "kv_rows" in manifest:
        rows = read("kv_rows").ravel()
        if rows.size != mask.shape[-1] or np.any((rows[allowed[-1]] < 0) | (rows[allowed[-1]] >= k.shape[2])):
            raise ValueError("visible mask columns refer to invalid physical KV slots")
        safe_rows = np.where(allowed[-1], rows, 0)
        k, v = k[:, :, safe_rows, :], v[:, :, safe_rows, :]
    if k.shape[2] != mask.shape[-1]:
        raise ValueError("mask columns do not match the KV view")

    # Unused cache cells can contain unrelated or uninitialized data.
    k = np.where(allowed[-1][None, None, :, None], k, 0)
    v = np.where(allowed[-1][None, None, :, None], v, 0)
    if any(not np.isfinite(t).all() for t in (q, k, v, actual)) or not np.any(actual):
        raise ValueError("invalid attention activation or output")
    return q, k, v, mask, actual, scale, counts.tolist()


def attention_reference(q, k, v, mask, scale):
    k = np.repeat(k.astype(np.float64), 2, axis=1)
    v = np.repeat(v.astype(np.float64), 2, axis=1)
    scores = (q.astype(np.float64) @ k.swapaxes(-1, -2)) * scale + mask
    probability = np.exp(scores - scores.max(axis=-1, keepdims=True))
    probability /= probability.sum(axis=-1, keepdims=True)
    return probability @ v


def write_attention_graph(path, feeds, shape, scale, *, fp32_compute=False):
    inputs = [helper.make_tensor_value_info(name, TensorProto.FLOAT16, value.shape) for name, value in feeds.items()]
    result = helper.make_tensor_value_info("Y", TensorProto.FLOAT16, shape)
    attention_inputs = list(feeds)
    nodes = []
    if fp32_compute:
        attention_inputs = [f"{name}_f32" for name in feeds]
        nodes.extend(helper.make_node("Cast", [name], [converted], to=TensorProto.FLOAT)
                     for name, converted in zip(feeds, attention_inputs))
    attention_output = "Y_f32" if fp32_compute else "Y"
    nodes.append(helper.make_node("Attention", attention_inputs, [attention_output], name="Layer0GQA", scale=scale))
    if fp32_compute:
        nodes.append(helper.make_node("Cast", [attention_output], ["Y"], to=TensorProto.FLOAT16))
    graph = helper.make_graph(nodes, "verify_layer0_attention", inputs, [result])
    save_onnx_graph(graph, path, opset=23)


def prepare(capture, output):
    q, k, v, mask, native, scale, counts = load_attention(capture)
    native_reference = compare(attention_reference(q, k, v, mask, scale), native)
    feeds = {name: np.ascontiguousarray(value, dtype=np.float16)
             for name, value in zip(("Q", "K", "V", "attn_mask"), (q, k, v, mask))}
    expected = attention_reference(*feeds.values(), scale).astype(np.float16)
    output.mkdir(parents=True, exist_ok=False)
    write_attention_graph(output / "verify_projection.onnx", feeds, expected.shape, scale)
    # Identical FP16 tensors at the boundary, with portable FP32 CPU arithmetic inside.
    write_attention_graph(output / "attention_cpu_fp32.onnx", feeds, expected.shape, scale, fp32_compute=True)
    np.savez(output / "input_and_reference.npz", **feeds, expected=expected, replay_kind="attention")

    report = {
        "independent_vs_native_capture": native_reference,
        "fp16_vs_native_capture": compare(expected, native),
        "cache_columns": int(k.shape[2]),
        "visible_keys_per_query": counts,
    }
    text = json.dumps(report, indent=2) + "\n"
    (output / "preparation.json").write_text(text, encoding="utf-8")
    print(text, end="")
    if native_reference["relative_l2_error"] > 0.01:
        raise ValueError("independent attention differs from native capture by more than 1% L2")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--capture", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    prepare(args.capture, args.output)


if __name__ == "__main__":
    main()

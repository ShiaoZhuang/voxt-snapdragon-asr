"""Replay one decoder layer from captured post-RoPE Q and staged K/V."""

import argparse
import json
from pathlib import Path

import gguf
import numpy as np
from onnx import TensorProto, helper, numpy_helper

from compare_capture import compare, load_weights
from prepare_attention import attention_reference, load_attention
from prepare_ffn import FfnGraph, add_swiglu, sigmoid
from projection import save_onnx_graph


def arrange_cache(capture, k, v, mask):
    manifest = json.loads((capture / "attention.json").read_text(encoding="utf-8"))

    def read_current(name):
        info = manifest[name]
        raw = np.fromfile(capture / info["file"], dtype=info["dtype"]).reshape(info["shape"])
        return raw.swapaxes(1, 2).astype(np.float16)

    current_k = read_current("current_k")
    current_v = read_current("current_v")
    if current_k.shape != (1, 8, 8, 128) or current_v.shape != current_k.shape:
        raise ValueError("expected eight newly produced K/V positions")
    allowed = mask[0, 0] == 0
    candidates = np.flatnonzero(allowed[0])

    def matches(slot, token):
        return (np.allclose(k[:, :, slot], current_k[:, :, token], rtol=0.001, atol=0.0005) and
                np.allclose(v[:, :, slot], current_v[:, :, token], rtol=0.001, atol=0.0005))

    anchor = [slot for slot in candidates if matches(slot, 0)]
    if len(anchor) != 1:
        raise ValueError(f"new anchor must match one KV cache slot, found {len(anchor)}")
    slots = anchor + [int(np.flatnonzero(allowed[i] & ~allowed[i - 1])[0]) for i in range(1, 8)]
    if any(not matches(slot, i) for i, slot in enumerate(slots)):
        raise ValueError("causal mask and captured new K/V disagree")
    prefix = np.setdiff1d(np.arange(k.shape[2]), slots)
    order = np.concatenate((prefix, slots))
    # Keep static cache capacity and permute K/V and the mask together.
    return {
        "past_key": k[:, :, prefix], "past_value": v[:, :, prefix],
        "K": current_k, "V": current_v, "attn_mask": mask[..., order],
    }, int(allowed[0].sum() - 1)


def read_weights(target):
    reader = gguf.GGUFReader(target)
    tensors = {t.name: t for t in reader.tensors}
    output = tensors["blk.0.attn_output.weight"]
    norm = tensors["blk.0.ffn_norm.weight"]
    if output.tensor_type != gguf.GGMLQuantizationType.Q8_0 or tuple(output.shape) != (2048, 2048):
        raise ValueError("unexpected Q8_0 attention output weight")
    if norm.tensor_type != gguf.GGMLQuantizationType.F32 or tuple(norm.shape) != (2048,):
        raise ValueError("unexpected FFN norm weight")
    epsilon = float(reader.get_field("qwen3vl.attention.layer_norm_rms_epsilon").contents())
    return gguf.dequantize(output.data, output.tensor_type), np.array(norm.data), epsilon


def normalize(x, weight, epsilon):
    return x * (1 / np.sqrt(np.mean(x * x, axis=-1, keepdims=True) + epsilon)) * weight


def build_graph(feeds, weights, norm, epsilon, scale, *, fp32_attention=False):
    output_weight, ffn_weights = weights
    graph = FfnGraph()
    graph.node("Concat", ["past_key", "K"], "joined_k", axis=2)
    graph.node("Concat", ["past_value", "V"], "joined_v", axis=2)
    attention_inputs = ["Q", "joined_k", "joined_v", "attn_mask"]
    if fp32_attention:
        for name in attention_inputs:
            graph.node("Cast", [name], f"{name}_f32", to=TensorProto.FLOAT)
        graph.node("Attention", [f"{name}_f32" for name in attention_inputs], "attention_f32", scale=scale)
        graph.node("Cast", ["attention_f32"], "attention", to=TensorProto.FLOAT16)
    else:
        graph.node("Attention", attention_inputs, "attention", scale=scale)

    k = np.concatenate((feeds["past_key"], feeds["K"]), axis=2)
    v = np.concatenate((feeds["past_value"], feeds["V"]), axis=2)
    attention = attention_reference(feeds["Q"], k, v, feeds["attn_mask"], scale).astype(np.float16)
    flat = attention.swapaxes(1, 2).reshape(8, 2048)
    graph.initializers["flat_shape"] = np.array([8, 2048], dtype=np.int64)
    graph.node("Transpose", ["attention"], "attention_seq", perm=[0, 2, 1, 3])
    graph.node("Reshape", ["attention_seq", "flat_shape"], "attention_flat")
    graph.node("Cast", ["attention_flat"], "attn_activation", to=TensorProto.FLOAT)
    _, attn_qdq = graph.activation("attn_activation", flat)
    _, attn_out = graph.activation("attn_linear", graph.project("attn_linear", "attn_activation", attn_qdq, output_weight))
    graph.node("Cast", ["attn_linear_dq"], "attn_linear_fp16", to=TensorProto.FLOAT16)
    graph.node("Add", ["attn_linear_fp16", "residual"], "ffn_residual")
    residual = (attn_out.astype(np.float16) + feeds["residual"]).astype(np.float32)

    graph.initializers["ffn_norm_weight"] = norm.astype(np.float16)
    graph.node("RMSNormalization", ["ffn_residual", "ffn_norm_weight"], "ffn_norm", axis=-1, epsilon=epsilon)
    graph.node("Cast", ["ffn_norm"], "ffn_activation", to=TensorProto.FLOAT)
    normed = normalize(residual, norm.astype(np.float16).astype(np.float32), epsilon).astype(np.float16)
    _, norm_qdq = graph.activation("ffn_activation", normed)
    _, ffn = add_swiglu(graph, "ffn_activation", norm_qdq, ffn_weights, "ffn_linear")
    graph.node("Cast", ["ffn_linear_dq"], "ffn_linear_fp16", to=TensorProto.FLOAT16)
    graph.node("Add", ["ffn_linear_fp16", "ffn_residual"], "layer_out")
    graph.node("Cast", ["layer_out"], "y", to=TensorProto.FLOAT)
    layer_out = ffn.astype(np.float16) + residual.astype(np.float16)
    expected, dequantized = graph.activation("y", layer_out, output_tensor=True)

    ins = [helper.make_tensor_value_info(name, TensorProto.FLOAT16, value.shape) for name, value in feeds.items()]
    outs = [helper.make_tensor_value_info("y_u16", TensorProto.UINT16, expected.shape)]
    model = helper.make_graph(graph.nodes, "verify_layer0_post_rope", ins, outs,
                              [numpy_helper.from_array(value, name) for name, value in graph.initializers.items()])
    return model, expected, dequantized


def prepare(capture, target, output):
    q, k, v, mask, native_attention, scale, counts = load_attention(capture)
    residual = np.fromfile(capture / "attention_residual.f32", dtype="<f4").reshape(8, 2048)
    native = np.fromfile(capture / "layer_out.f32", dtype="<f4").reshape(8, 2048)
    cache, history = arrange_cache(capture, k, v, mask)
    feeds = {name: np.ascontiguousarray(value, dtype=np.float16)
             for name, value in {"Q": q, "residual": residual, **cache}.items()}
    output_weight, norm, epsilon = read_weights(target)
    ffn_weights = tuple(load_weights(target, ["up", "gate", "down"]))

    dense_residual = residual + native_attention.swapaxes(1, 2).reshape(8, 2048) @ output_weight.T
    normed = normalize(dense_residual, norm, epsilon)
    w_up, w_gate, w_down = ffn_weights
    gate = normed @ w_gate.T
    dense = dense_residual + (gate * sigmoid(gate) * (normed @ w_up.T)) @ w_down.T

    weights = (output_weight, ffn_weights)
    model, expected, dequantized = build_graph(feeds, weights, norm, epsilon, scale)
    cpu_model, _, _ = build_graph(feeds, weights, norm, epsilon, scale, fp32_attention=True)
    output.mkdir(parents=True, exist_ok=False)
    save_onnx_graph(model, output / "verify_projection.onnx", opset=23)
    save_onnx_graph(cpu_model, output / "attention_cpu_fp32.onnx", opset=23)
    np.savez(output / "input_and_reference.npz", **feeds, expected=expected, replay_kind="decoder-layer")
    report = {
        "dense_vs_native_capture": compare(dense, native),
        "mixed_precision_vs_dense": compare(dequantized, dense),
        "mixed_precision_vs_native_capture": compare(dequantized, native),
        "history_tokens": history, "staged_tokens": 8, "cache_columns": int(k.shape[2]),
        "visible_keys_per_query": counts,
    }
    text = json.dumps(report, indent=2) + "\n"
    (output / "preparation.json").write_text(text, encoding="utf-8")
    print(text, end="")
    if report["dense_vs_native_capture"]["relative_l2_error"] > 0.03:
        raise ValueError("dense reconstruction differs from native layer output by more than 3% L2")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--capture", required=True, type=Path)
    parser.add_argument("--target", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    prepare(args.capture, args.target, args.output)


if __name__ == "__main__":
    main()

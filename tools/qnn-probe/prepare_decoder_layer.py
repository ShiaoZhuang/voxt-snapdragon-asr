"""Replay layer 0 from either the hidden state or captured post-RoPE Q/K/V."""

import argparse
import json
from pathlib import Path

import gguf
import numpy as np
from onnx import TensorProto, helper, numpy_helper

from compare_capture import compare
from prepare_attention import attention_reference, load_attention
from prepare_ffn import FfnGraph, add_swiglu, sigmoid
from projection import save_onnx_graph


MAX_NATIVE_STAGE_L2 = 0.05


def read_tensor(capture, manifest, name):
    info = manifest[name]
    return np.fromfile(capture / info["file"], dtype=info["dtype"]).reshape(info["shape"])


def arrange_cache(capture, manifest, k, v, mask):
    current_k, current_v = (read_tensor(capture, manifest, name).swapaxes(1, 2).astype(np.float16)
                            for name in ("current_k", "current_v"))
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


def read_weight(tensors, layer, name, shape, *, quantized=False):
    tensor = tensors[f"blk.{layer}.{name}.weight"]
    expected = gguf.GGMLQuantizationType.Q8_0 if quantized else gguf.GGMLQuantizationType.F32
    if tensor.tensor_type != expected or tuple(tensor.shape) != shape:
        raise ValueError(f"unexpected type or shape for {tensor.name}")
    return gguf.dequantize(tensor.data, expected) if quantized else np.array(tensor.data)


def normalize(x, weight, epsilon):
    return x * (1 / np.sqrt(np.mean(x * x, axis=-1, keepdims=True) + epsilon)) * weight


def native_boundaries(capture, residual, native, attention, projected, norm, epsilon, ffn):
    """Check each native operation with its actual inputs, independent of upstream drift."""
    def read(name, width=2048):
        values = np.fromfile(capture / f"{name}.f32", dtype="<f4").reshape(8, width)
        if not np.isfinite(values).all():
            raise ValueError(f"nonfinite native boundary: {name}")
        return values

    ffn_in, ffn_norm, down = (read(name) for name in ("ffn_inp", "ffn_norm", "ffn_out"))
    up, gate, swiglu = (read(name, 6144) for name in ("ffn_up", "ffn_gate", "ffn_swiglu"))
    w_up, w_gate, w_down = ffn
    boundaries = {
        "attention": compare(attention[0], attention[1]),
        # ggml can reuse the projection buffer for the addition; recover the contribution from both captured states.
        "attention_output_projection": compare(projected, ffn_in.astype(np.float64) - residual),
        "ffn_norm": compare(normalize(ffn_in, norm, epsilon), ffn_norm),
        "ffn_up": compare(ffn_norm @ w_up.T, up),
        "ffn_gate": compare(ffn_norm @ w_gate.T, gate),
        "ffn_swiglu": compare(gate * sigmoid(gate) * up, swiglu),
        "ffn_down": compare(swiglu @ w_down.T, down),
    }
    boundaries["output_residual"] = compare(ffn_in + down, native)
    if boundaries["output_residual"]["relative_l2_error"] > 1e-5:
        raise ValueError(f"inconsistent native capture at output residual: {boundaries['output_residual']}")
    return boundaries


def rotary_tables(capture, manifest):
    if "rope" not in manifest:
        raise ValueError("capture did not include layer-0 RoPE positions and parameters")
    rope = manifest["rope"]
    if (rope["mode"] != 40 or rope["dims"] != 128 or rope["offset"] != 0 or
            rope["ext_factor"] != 0 or rope["base"] <= 0 or sum(rope["sections"]) <= 0):
        raise ValueError(f"unsupported interleaved M-RoPE settings: {rope}")
    positions = read_tensor(capture, manifest, "rope_positions").reshape(4, 8)
    return rotary_tables_for_positions(rope, positions)


def rotary_tables_for_positions(rope, positions):
    t, h, w, _ = rope["sections"]
    frequencies = np.arange(64)
    sector = frequencies % sum(rope["sections"])
    axes = np.select([(sector % 3 == i) & (sector < 3 * count)
                      for i, count in enumerate((t, h, w))], [0, 1, 2], default=3)
    phase = positions[axes, :].T * rope["base"] ** (-frequencies / 64) * rope["freq_scale"]
    return tuple((function(phase) * rope["attn_factor"])[None, None]
                 for function in (np.cos, np.sin))


def rotate(x, cosine, sine):
    left, right = np.split(x, 2, axis=-1)
    return np.concatenate((left * cosine - right * sine, right * cosine + left * sine), axis=-1)


def project_qkv(graph, x, weights, norms, epsilon, tables, *, live=False):
    input_norm, q_norm, k_norm = norms
    precision = np.float16 if graph else np.float32
    cosine, sine = (table.astype(precision) for table in tables)
    normalized = normalize(x.astype(precision).astype(np.float32), input_norm.astype(precision), epsilon)
    if graph:
        graph.initializers.update({
            "attn_input_norm_weight": input_norm.astype(precision),
            "rope_cos": np.concatenate((cosine, cosine), axis=-1),
            "rope_sin": np.concatenate((-sine, sine), axis=-1),
            "rope_swap_halves": np.r_[64:128, 0:64].astype(np.int64),
        })
        if live:
            del graph.initializers["rope_cos"], graph.initializers["rope_sin"]
        graph.node("RMSNormalization", ["residual", "attn_input_norm_weight"], "attn_input_norm", axis=-1, epsilon=epsilon)
        graph.node("Cast", ["attn_input_norm"], "qkv_input", to=TensorProto.FLOAT)
        _, qkv_input = graph.activation("qkv_input", normalized.astype(precision))
    result = {}
    for name, weight, heads, norm in zip(("Q", "K", "V"), weights, (16, 8, 8), (q_norm, k_norm, None)):
        projection = f"{name}_linear"
        if graph:
            values = graph.project(projection, "qkv_input", qkv_input, weight)
            _, values = graph.activation(projection, values)
            graph.initializers[f"{name}_head_shape"] = np.array([1, 8, heads, 128], dtype=np.int64)
            graph.node("Cast", [f"{projection}_dq"], f"{name}_math", to=TensorProto.FLOAT16)
            graph.node("Reshape", [f"{name}_math", f"{name}_head_shape"], f"{name}_seq")
            graph.node("Transpose", [f"{name}_seq"], f"{name}_heads", perm=[0, 2, 1, 3])
        else:
            values = normalized @ weight.T
        values = values.astype(precision).reshape(1, 8, heads, 128).swapaxes(1, 2)
        source = f"{name}_heads"
        if norm is not None:
            values = normalize(values.astype(np.float32), norm.astype(precision), epsilon).astype(precision)
            if graph:
                graph.initializers[f"{name}_norm_weight"] = norm.astype(precision)
                graph.node("RMSNormalization", [source, f"{name}_norm_weight"], f"{name}_norm", axis=-1, epsilon=epsilon)
                graph.node("Gather", [f"{name}_norm", "rope_swap_halves"], f"{name}_swapped", axis=3)
                graph.node("Mul", [f"{name}_norm", "rope_cos"], f"{name}_cos")
                graph.node("Mul", [f"{name}_swapped", "rope_sin"], f"{name}_sin")
                graph.node("Add", [f"{name}_cos", f"{name}_sin"], f"{name}_rotated")
                source = f"{name}_rotated"
            values = rotate(values, cosine, sine)
        if graph:
            graph.node("Identity", [source], name)
        result[name] = values.astype(np.float16) if graph else values
    return result


def build_graph(feeds, weights, norm, epsilon, scale, *, front=None, fp32_attention=False, activation_code_limit=32000, live=False):
    output_weight, ffn_weights = weights
    graph = FfnGraph(activation_code_limit)
    if front:
        qkv = project_qkv(graph, feeds["residual"], *front, live=live)
    else:
        qkv = feeds
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

    k = np.concatenate((feeds["past_key"], qkv["K"]), axis=2)
    v = np.concatenate((feeds["past_value"], qkv["V"]), axis=2)
    attention = attention_reference(qkv["Q"], k, v, feeds["attn_mask"], scale).astype(np.float16)
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
    if live:
        ins += [helper.make_tensor_value_info(name, TensorProto.FLOAT16, [1, 1, 8, 128])
                for name in ("rope_cos", "rope_sin")]
        outs += [helper.make_tensor_value_info(name, TensorProto.FLOAT16, [1, 8, 8, 128])
                 for name in ("K", "V")]
    model = helper.make_graph(graph.nodes, "verify_layer0_full" if front else "verify_layer0_post_rope", ins, outs,
                              [numpy_helper.from_array(value, name) for name, value in graph.initializers.items()])
    return model, expected, dequantized, float(graph.initializers["y_scale"])


def prepare(capture, target, output, *, full=False, layer=0, activation_code_limit=32000, verbose=True,
            allow_reference_mismatch=False, live=False, live_cpu=False):
    q, k, v, mask, native_attention, scale, counts = load_attention(capture)
    residual = np.fromfile(capture / "attention_residual.f32", dtype="<f4").reshape(8, 2048)
    native = np.fromfile(capture / "layer_out.f32", dtype="<f4").reshape(8, 2048)
    manifest = json.loads((capture / "attention.json").read_text(encoding="utf-8"))
    cache, history = arrange_cache(capture, manifest, k, v, mask)
    feeds = {name: np.ascontiguousarray(value, dtype=np.float16)
             for name, value in {"Q": q, "residual": residual, **cache}.items()}
    reader = target if isinstance(target, gguf.GGUFReader) else gguf.GGUFReader(target)
    tensors = {t.name: t for t in reader.tensors}
    output_weight = read_weight(tensors, layer, "attn_output", (2048, 2048), quantized=True)
    norm = read_weight(tensors, layer, "ffn_norm", (2048,))
    epsilon = float(reader.get_field("qwen3vl.attention.layer_norm_rms_epsilon").contents())
    ffn_weights = tuple(read_weight(tensors, layer, f"ffn_{name}", shape, quantized=True)
                        for name, shape in (("up", (2048, 6144)), ("gate", (2048, 6144)), ("down", (6144, 2048))))

    front = None
    front_errors = {}
    dense_attention = native_attention
    if full:
        qkv_weights = tuple(read_weight(tensors, layer, f"attn_{name}", (2048, width), quantized=True)
                            for name, width in (("q", 2048), ("k", 1024), ("v", 1024)))
        qkv_norms = tuple(read_weight(tensors, layer, name, (width,))
                          for name, width in (("attn_norm", 2048), ("attn_q_norm", 128), ("attn_k_norm", 128)))
        front = qkv_weights, qkv_norms, epsilon, rotary_tables(capture, manifest)
        rebuilt = project_qkv(None, residual, *front)
        front_errors = {name: compare(rebuilt[name], feeds.pop(name).astype(np.float32))
                        for name in ("Q", "K", "V")}
        dense_k = np.concatenate((feeds["past_key"], rebuilt["K"]), axis=2)
        dense_v = np.concatenate((feeds["past_value"], rebuilt["V"]), axis=2)
        dense_attention = attention_reference(rebuilt["Q"], dense_k, dense_v, feeds["attn_mask"], scale).astype(np.float32)

    dense_residual = residual + dense_attention.swapaxes(1, 2).reshape(8, 2048) @ output_weight.T
    normed = normalize(dense_residual, norm, epsilon)
    w_up, w_gate, w_down = ffn_weights
    gate = normed @ w_gate.T
    dense = dense_residual + (gate * sigmoid(gate) * (normed @ w_up.T)) @ w_down.T
    dense_gap = compare(dense, native)
    boundaries = {}
    if (capture / "ffn_inp.f32").exists():
        attn_from_native = attention_reference(q, k, v, mask, scale)
        attn_projection = native_attention.swapaxes(1, 2).reshape(8, 2048) @ output_weight.T
        boundaries = native_boundaries(capture, residual, native, (attn_from_native, native_attention),
                                       attn_projection, norm, epsilon, ffn_weights)
    reference_checks = {**front_errors, **(boundaries or {"dense_output": dense_gap})}
    failed_checks = [name for name, metrics in reference_checks.items()
                     if not metrics["relative_l2_error"] <= MAX_NATIVE_STAGE_L2]
    if failed_checks and not allow_reference_mismatch:
        details = ", ".join(f"{name}={reference_checks[name]['relative_l2_error']:.3%}" for name in failed_checks)
        raise ValueError(f"Native reconstruction exceeds {MAX_NATIVE_STAGE_L2:.0%} relative L2: {details}")

    weights = (output_weight, ffn_weights)
    model, expected, dequantized, output_scale = build_graph(
        feeds, weights, norm, epsilon, scale, front=front, activation_code_limit=activation_code_limit, live=live,
        fp32_attention=live_cpu)
    if live:
        return model, feeds, output_scale
    cpu_model, _, _, _ = build_graph(
        feeds, weights, norm, epsilon, scale, front=front, activation_code_limit=activation_code_limit, fp32_attention=True)
    output.mkdir(parents=True, exist_ok=False)
    save_onnx_graph(model, output / "verify_projection.onnx", opset=23)
    save_onnx_graph(cpu_model, output / "attention_cpu_fp32.onnx", opset=23)
    kind = "full-decoder" if full else "decoder-layer"
    np.savez(output / "input_and_reference.npz", **feeds, expected=expected, replay_kind=kind)
    report = {
        "dense_vs_native_capture": dense_gap,
        "mixed_precision_vs_dense": compare(dequantized, dense),
        "mixed_precision_vs_native_capture": compare(dequantized, native),
        "history_tokens": history, "staged_tokens": 8, "cache_columns": int(k.shape[2]),
        "visible_keys_per_query": counts,
        "dense_qkv_vs_native": front_errors,
        "native_boundaries": boundaries,
        "failed_native_checks": failed_checks,
        "output_scale": output_scale,
    }
    text = json.dumps(report, indent=2) + "\n"
    (output / "preparation.json").write_text(text, encoding="utf-8")
    if verbose:
        print(text, end="")
    return feeds, expected, report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--capture", required=True, type=Path)
    parser.add_argument("--target", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--full", action="store_true")
    args = parser.parse_args()
    prepare(args.capture, args.target, args.output, full=args.full)


if __name__ == "__main__":
    main()

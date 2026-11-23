"""Replay one real eight-position Target batch through all decoder layers."""

import argparse
import json
from pathlib import Path
from tempfile import TemporaryDirectory
import time

import gguf
import numpy as np
import onnxruntime as ort

from compare_capture import compare
from prepare_decoder_layer import normalize, prepare
from projection import (
    ATTENTION_MAX_ERROR_OF_PEAK, ATTENTION_MAX_RELATIVE_L2, INPUT_SHAPE, QNN_PROVIDER,
    compare_output, htp_execute_events, htp_session_options,
)


def load_hidden(path):
    state = np.fromfile(path, dtype="<f4").reshape(INPUT_SHAPE)
    if not np.isfinite(state).all():
        raise ValueError(f"nonfinite hidden state in {path}")
    return state


def hidden_from_codes(codes, scale):
    return ((codes.astype(np.float32) - 32768) * scale).astype(np.float16)


def compare_codes(actual, reference, backend):
    result = compare_output(actual, reference, relative_limits=(
        ATTENTION_MAX_RELATIVE_L2[backend], ATTENTION_MAX_ERROR_OF_PEAK[backend]))
    return {key: result[key] for key in ("relative_l2_error", "max_error_fraction_of_reference_peak", "accuracy_passed")}


def run_htp(qnn, model, profile, feeds):
    options, run_options, devices = htp_session_options(qnn, profile)
    session = ort.InferenceSession(str(model), sess_options=options, enable_fallback=False)
    try:
        if QNN_PROVIDER not in session.get_providers():
            raise RuntimeError(f"QNN provider was not selected: {session.get_providers()}")
        session.run(None, feeds, run_options)  # Warm the static layer before timing it.
        times = []
        for _ in range(3):
            start = time.perf_counter()
            output, = session.run(None, feeds, run_options)
            times.append((time.perf_counter() - start) * 1000)
        return output, float(np.median(times)), htp_execute_events(session.end_profiling())
    finally:
        del session, options, devices


def run_layer(capture, target, layer, directory, cpu_hidden, htp_hidden, qnn, profile):
    feeds, expected, prep = prepare(
        capture, target, directory, full=True, layer=layer, activation_code_limit=24576, verbose=False)
    native = load_hidden(capture / "layer_out.f32")
    # Graphs use the same code range on both backends. Keep headroom for chained states.
    scale = prep["output_scale"]
    options = ort.SessionOptions()
    options.intra_op_num_threads = 4
    session = ort.InferenceSession(str(directory / "attention_cpu_fp32.onnx"), sess_options=options,
                                   providers=["CPUExecutionProvider"], enable_fallback=False)
    captured_codes, = session.run(None, feeds)
    cpu_check = compare_codes(captured_codes, expected, "cpu")
    cpu_codes = captured_codes
    if cpu_hidden is not None:
        cpu_codes, = session.run(None, {**feeds, "residual": cpu_hidden})
    next_cpu = hidden_from_codes(cpu_codes, scale)
    result = {
        "cpu_vs_independent": cpu_check,
        "cpu_chain_vs_native": compare(next_cpu, native),
        "cpu_output_clipped": bool(np.any((cpu_codes == 0) | (cpu_codes == 65535))),
    }
    if not qnn:
        return next_cpu, None, result

    htp_feeds = feeds
    cpu_pair = captured_codes
    if htp_hidden is not None:
        htp_feeds = {**feeds, "residual": htp_hidden}
        cpu_pair, = session.run(None, htp_feeds)
    htp_codes, median, events = run_htp(qnn, directory / "verify_projection.onnx", profile, htp_feeds)
    next_htp = hidden_from_codes(htp_codes, scale)
    result.update({
        "htp_vs_cpu_same_input": compare_codes(htp_codes, cpu_pair, "htp"),
        "htp_chain_vs_native": compare(next_htp, native),
        "htp_output_clipped": bool(np.any((htp_codes == 0) | (htp_codes == 65535))),
        "host_median_ms": median,
        "qaairt_execute_events": events,
    })
    return next_cpu, next_htp, result


def read_head(target, columns):
    tensors = {tensor.name: tensor for tensor in target.tensors}
    weight, norm = tensors["output.weight"], tensors["output_norm.weight"]
    if (tuple(weight.shape) != (INPUT_SHAPE[1], columns) or
            weight.tensor_type != gguf.GGMLQuantizationType.Q8_0 or
            tuple(norm.shape) != (INPUT_SHAPE[1],) or norm.tensor_type != gguf.GGMLQuantizationType.F32):
        raise ValueError("unexpected Target head dimensions or weight types")
    epsilon = float(target.get_field("qwen3vl.attention.layer_norm_rms_epsilon").contents())
    return weight, np.asarray(norm.data), epsilon


def score_logits(target, native_logits, states):
    weight, norm, epsilon = read_head(target, native_logits.shape[1])
    x = normalize(np.concatenate(list(states.values())).astype(np.float32), norm, epsilon)
    scores = np.empty((len(x), native_logits.shape[1]), dtype=np.float32)
    for start in range(0, scores.shape[1], 4096):
        end = min(start + 4096, scores.shape[1])
        weights = gguf.dequantize(weight.data[start:end], weight.tensor_type)
        scores[:, start:end] = x @ weights.T
    reference_ids = np.argmax(native_logits, axis=1)
    if not np.isfinite(scores).all():
        raise ValueError("nonfinite scores from the reference head")
    results = {}
    for name, logits in zip(states, np.split(scores, len(states))):
        ids = np.argmax(logits, axis=1)
        results[name] = {
            "top1": ids.tolist(),
            "matches": int(np.count_nonzero(ids == reference_ids)),
            **compare(logits, native_logits),
        }
    return reference_ids.tolist(), results


def run(args, qnn):
    args.output.mkdir(parents=True, exist_ok=False)
    manifest = json.loads((args.capture / "capture.json").read_text(encoding="utf-8"))
    target = gguf.GGUFReader(args.target)
    layer_count = int(target.get_field("qwen3vl.block_count").contents())
    columns = int(manifest["logit_columns"])
    if layer_count != manifest["layer_count"] or columns <= 0:
        raise ValueError("capture must include every Target layer and its native logits")
    native_logits = np.fromfile(args.capture / "target_logits.f32", dtype="<f4").reshape(INPUT_SHAPE[0], columns)
    if not np.isfinite(native_logits).all():
        raise ValueError("nonfinite native logits")
    draft = gguf.GGUFReader(args.draft)
    aux_layers = draft.get_field("dflash.target_layers").contents()
    if not aux_layers or any(not 0 <= i < layer_count for i in aux_layers):
        raise ValueError(f"invalid DFlash auxiliary layers: {aux_layers}")

    checked = []
    aux = {}
    cpu_hidden = htp_hidden = native_output = None
    connected = True
    passing = True
    with (args.output / "target-layers.jsonl").open("w", encoding="utf-8", buffering=1) as log:
        for layer in range(layer_count):
            folder = args.capture if layer == 0 else args.capture / f"layer-{layer}"
            result = {"layer": layer}
            try:
                native_input = load_hidden(folder / "attention_residual.f32")
                if native_output is not None and not np.array_equal(native_input, native_output):
                    raise ValueError("native layer output does not equal the following layer input")
                native_output = load_hidden(folder / "layer_out.f32")
                if layer in aux_layers and cpu_hidden is not None:
                    aux[layer] = {"cpu_chain_vs_native": compare(cpu_hidden, native_input)}
                    if htp_hidden is not None:
                        aux[layer]["htp_chain_vs_native"] = compare(htp_hidden, native_input)
                with TemporaryDirectory(prefix=f"layer-{layer}-", dir=args.output) as temporary:
                    cpu_hidden, htp_hidden, metrics = run_layer(
                        folder, target, layer, Path(temporary) / "fixture", cpu_hidden, htp_hidden, qnn,
                        args.output / f"htp-layer-{layer}")
                result.update(metrics)
                result["passed"] = metrics["cpu_vs_independent"]["accuracy_passed"] and not metrics["cpu_output_clipped"]
                if qnn:
                    result["passed"] &= (metrics["htp_vs_cpu_same_input"]["accuracy_passed"] and
                                         metrics["qaairt_execute_events"] > 0 and not metrics["htp_output_clipped"])
            except Exception as error:
                # Continue from the next native snapshot so one broken layer cannot hide later ones.
                result.update(passed=False, error=f"{type(error).__name__}: {error}")
                cpu_hidden = htp_hidden = native_output = None
                connected = False
            checked.append(result)
            passing &= result["passed"]
            log.write(json.dumps(result) + "\n")
            print(f"Decoder {layer + 1}/{layer_count}: {'PASS' if result['passed'] else 'FAIL'}", flush=True)

    report = {
        "backend": args.backend, "layer_count": layer_count, "chain_complete": connected,
        "cpu_layers_passed": sum(bool(info.get("cpu_vs_independent", {}).get("accuracy_passed")) for info in checked),
        "htp_layers_passed": sum(bool(info.get("htp_vs_cpu_same_input", {}).get("accuracy_passed"))
                                 and info.get("qaairt_execute_events", 0) > 0 for info in checked) if qnn else None,
        "failed_layers": [info["layer"] for info in checked if not info["passed"]],
        "errors": {info["layer"]: info["error"] for info in checked if "error" in info},
        "htp_layer_ms_sum": sum(info.get("host_median_ms", 0) for info in checked) if qnn else None,
        "htp_events": sum(info.get("qaairt_execute_events", 0) for info in checked) if qnn else None,
        "aux": aux,
        "logits": {},
    }
    if connected:
        states = {"native_hidden": native_output, "cpu_chain": cpu_hidden}
        if qnn:
            states["htp_chain"] = htp_hidden
        report["native_top1"], report["logits"] = score_logits(target, native_logits, states)
        passing &= all(result["matches"] == INPUT_SHAPE[0] for result in report["logits"].values())
        passing &= len(aux) == len(aux_layers)
    report["passed"] = passing and connected
    (args.output / "target_replay.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    return report["passed"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--backend", choices=["htp", "cpu"], default="htp")
    for name in ("capture", "target", "draft", "output"):
        parser.add_argument(f"--{name}", required=True, type=Path)
    args = parser.parse_args()
    if args.backend == "cpu":
        return 0 if run(args, None) else 1
    import onnxruntime_qnn as qnn

    ort.register_execution_provider_library(QNN_PROVIDER, qnn.get_library_path())
    try:
        return 0 if run(args, qnn) else 1
    finally:
        ort.unregister_execution_provider_library(QNN_PROVIDER)


if __name__ == "__main__":
    raise SystemExit(main())

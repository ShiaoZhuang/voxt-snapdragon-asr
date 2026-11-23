"""Replay one real eight-position Target batch through all decoder layers."""

import argparse
import json
from pathlib import Path
import subprocess
import sys
from tempfile import TemporaryDirectory
import time

import gguf
import numpy as np
import onnxruntime as ort

from compare_capture import compare
from prepare_decoder_layer import normalize, prepare
from projection import (
    ATTENTION_MAX_ERROR_OF_PEAK, ATTENTION_MAX_RELATIVE_L2, INPUT_SHAPE, compare_output,
)


HTP_TIMEOUT_SECONDS = 45
REPLAY_BUDGET_SECONDS = 270


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


def run_htp(model, profile, feeds, timeout):
    request, response = (model.parent / name for name in ("htp_request.npz", "htp_response.npz"))
    np.savez(request, **feeds)
    worker = Path(__file__).with_name("target_htp_worker.py")
    command = [sys.executable, "-X", "utf8", str(worker), *map(str, (model, request, profile, response))]
    error = None
    stderr_path = profile.with_suffix(".stderr.log")
    with profile.with_suffix(".stdout.log").open("wb") as stdout, stderr_path.open("wb") as stderr:
        try:
            process = subprocess.run(command, stdout=stdout, stderr=stderr, timeout=timeout, check=False)
            if process.returncode:
                error = f"HTP worker exit {process.returncode} (0x{process.returncode & 0xffffffff:08X})"
        except subprocess.TimeoutExpired:
            error = f"HTP worker timed out after {timeout:.1f}s"
    if error:
        phase_file = profile.with_suffix(".phase.txt")
        phase = phase_file.read_text(encoding="utf-8").strip() if phase_file.is_file() else "start worker"
        error += f" at {phase} ({profile.name})"
        if error.startswith("HTP worker exit"):
            with stderr_path.open("rb") as stderr:
                stderr.seek(max(0, stderr_path.stat().st_size - 1024))
                tail = stderr.read().decode("utf-8", errors="replace").rstrip().splitlines()
            if tail:
                error += f": {tail[-1][-240:]}"
    if not response.is_file():
        return None, None, 0, error or "HTP worker returned no result"
    with np.load(response, allow_pickle=False) as data:
        return data["output"], float(data["median_ms"]), int(data["events"]), error


def run_layer(capture, target, layer, directory, cpu_hidden, htp_hidden, use_htp, profile, progress,
              *, final=False, timeout=HTP_TIMEOUT_SECONDS):
    progress("prepare graph")
    feeds, expected, prep = prepare(
        capture, target, directory, full=True, layer=layer, activation_code_limit=24576, verbose=False,
        allow_reference_mismatch=True)
    reference = {
        "dense_output_l2": prep["dense_vs_native_capture"]["relative_l2_error"],
        "stage_l2": {name: value["relative_l2_error"] for name, value in
                     {**prep["dense_qkv_vs_native"], **prep["native_boundaries"]}.items()},
        "boundary_capture": bool(prep["native_boundaries"]),
        "failed_checks": prep["failed_native_checks"],
    }
    if final:
        (profile.parent / "last-layer-reference.json").write_text(json.dumps(reference, indent=2) + "\n", encoding="utf-8")
    native = load_hidden(capture / "layer_out.f32")
    # Graphs use the same code range on both backends. Keep headroom for chained states.
    scale = prep["output_scale"]
    progress("CPU reference")
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
        "native_reference": reference,
        "cpu_vs_independent": cpu_check,
        "cpu_chain_vs_native": compare(next_cpu, native),
        "cpu_output_clipped": bool(np.any((cpu_codes == 0) | (cpu_codes == 65535))),
    }
    htp_feeds = feeds
    cpu_pair = captured_codes
    if use_htp and htp_hidden is not None:
        htp_feeds = {**feeds, "residual": htp_hidden}
        cpu_pair, = session.run(None, htp_feeds)
    del session, options
    if not use_htp:
        return next_cpu, None, result
    progress("HTP worker", profile.name)
    htp_codes, median, events, error = run_htp(directory / "verify_projection.onnx", profile, htp_feeds, timeout)
    if error:
        result["error"] = error
    if htp_codes is None:
        return next_cpu, None, result
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


def write_json(path, value):
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")
    temporary.replace(path)


def run(args, use_htp):
    args.output.mkdir(parents=True, exist_ok=False)
    deadline = time.monotonic() + REPLAY_BUDGET_SECONDS
    progress_path = args.output / "target-progress.json"

    def progress(phase, *, layer=None, worker=None):
        write_json(progress_path, {"phase": phase, "layer": layer, "worker": worker})

    progress("read captured batch and models")
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

    last_index = layer_count - 1
    last_folder = args.capture if last_index == 0 else args.capture / f"layer-{last_index}"
    native_last = load_hidden(last_folder / "layer_out.f32")
    isolated_htp = None
    isolated = None
    if use_htp:
        def isolated_progress(phase, worker=None):
            progress(f"isolated last layer: {phase}", layer=last_index, worker=worker)

        try:
            with TemporaryDirectory(prefix="last-isolated-", dir=args.output) as temporary:
                _, isolated_htp, isolated = run_layer(
                    last_folder, target, last_index, Path(temporary) / "fixture", None, None, True,
                    args.output / "htp-last-isolated", isolated_progress, final=True, timeout=HTP_TIMEOUT_SECONDS)
        except Exception as error:
            isolated = {"error": f"{type(error).__name__}: {error}"}
        write_json(args.output / "last-layer-isolated.json", isolated)

    checked = []
    aux = {}
    cpu_hidden = htp_hidden = native_output = None
    cpu_connected = htp_connected = True
    passing = True
    budget_exhausted = False
    with (args.output / "target-layers.jsonl").open("w", encoding="utf-8", buffering=1) as log:
        for layer in range(layer_count):
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                budget_exhausted = True
                break
            folder = args.capture if layer == 0 else args.capture / f"layer-{layer}"
            result = {"layer": layer}

            def layer_progress(phase, worker=None):
                progress(phase, layer=layer, worker=worker)

            try:
                layer_progress("validate capture")
                native_input = load_hidden(folder / "attention_residual.f32")
                if native_output is not None and not np.array_equal(native_input, native_output):
                    raise ValueError("native layer output does not equal the following layer input")
                native_output = load_hidden(folder / "layer_out.f32")
                if layer in aux_layers and cpu_hidden is not None:
                    aux[layer] = {"cpu_chain_vs_native": compare(cpu_hidden, native_input)}
                    if htp_hidden is not None:
                        aux[layer]["htp_chain_vs_native"] = compare(htp_hidden, native_input)
                with TemporaryDirectory(prefix=f"layer-{layer}-", dir=args.output) as temporary:
                    run_device = use_htp and (layer != last_index or isolated_htp is not None)
                    cpu_hidden, htp_hidden, metrics = run_layer(
                        folder, target, layer, Path(temporary) / "fixture", cpu_hidden, htp_hidden, run_device,
                        args.output / f"htp-layer-{layer}", layer_progress,
                        final=layer == last_index, timeout=min(HTP_TIMEOUT_SECONDS, remaining))
                result.update(metrics)
                result["passed"] = (metrics["cpu_vs_independent"]["accuracy_passed"] and
                                    not metrics["cpu_output_clipped"] and not metrics["native_reference"]["failed_checks"])
                if use_htp:
                    if not run_device:
                        result["error"] = "Chained last-layer HTP skipped after isolated execution produced no result"
                    htp_connected &= htp_hidden is not None
                    result["passed"] &= htp_passed(metrics)
            except Exception as error:
                # Continue from the next native snapshot so one broken layer cannot hide later ones.
                result.update(passed=False, error=f"{type(error).__name__}: {error}")
                cpu_hidden = htp_hidden = native_output = None
                cpu_connected = htp_connected = False
            checked.append(result)
            passing &= result["passed"]
            log.write(json.dumps(result) + "\n")
            print(f"Decoder {layer + 1}/{layer_count}: {'PASS' if result['passed'] else 'FAIL'}", flush=True)

    cpu_complete = cpu_connected and len(checked) == layer_count
    htp_complete = use_htp and htp_connected and len(checked) == layer_count
    connected = htp_complete if use_htp else cpu_complete
    report = {
        "backend": args.backend, "layer_count": layer_count, "chain_complete": connected,
        "layers_checked": len(checked), "budget_exhausted": budget_exhausted,
        "last_isolated": isolated,
        "cpu_layers_passed": sum(bool(info.get("cpu_vs_independent", {}).get("accuracy_passed")) for info in checked),
        "htp_layers_passed": sum(htp_passed(info) for info in checked) if use_htp else None,
        "failed_layers": [info["layer"] for info in checked if not info["passed"]],
        "errors": {info["layer"]: info["error"] for info in checked if "error" in info},
        "native_reference_failures": {info["layer"]: info["native_reference"]["failed_checks"] for info in checked
                                      if info.get("native_reference", {}).get("failed_checks")},
        "last_layer": checked[-1] if len(checked) == layer_count else None,
        "htp_layer_ms_sum": sum(info.get("host_median_ms", 0) for info in checked) if use_htp else None,
        "htp_events": sum(info.get("qaairt_execute_events", 0) for info in checked) if use_htp else None,
        "aux": aux,
        "logits": {},
    }
    states = {"native_hidden": native_last}
    if cpu_complete:
        states["cpu_chain"] = cpu_hidden
    if htp_complete:
        states["htp_chain"] = htp_hidden
    if isolated_htp is not None:
        states["htp_isolated"] = isolated_htp
    write_json(args.output / "target_replay.json", {**report, "passed": False})
    progress("host logits")
    try:
        report["native_top1"], report["logits"] = score_logits(target, native_logits, states)
        passing &= all(result["matches"] == INPUT_SHAPE[0] for name, result in report["logits"].items()
                       if name != "htp_isolated")
        passing &= len(aux) == len(aux_layers)
    except Exception as error:
        report["logits_error"] = f"{type(error).__name__}: {error}"
        passing = False
    report["passed"] = passing and connected and (not use_htp or htp_passed(isolated))
    write_json(args.output / "target_replay.json", report)
    progress("complete")
    return report["passed"]


def htp_passed(metrics):
    return (bool(metrics.get("htp_vs_cpu_same_input", {}).get("accuracy_passed")) and
            metrics.get("qaairt_execute_events", 0) > 0 and not metrics["htp_output_clipped"] and
            not metrics.get("error"))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--backend", choices=["htp", "cpu"], default="htp")
    for name in ("capture", "target", "draft", "output"):
        parser.add_argument(f"--{name}", required=True, type=Path)
    args = parser.parse_args()
    return 0 if run(args, args.backend == "htp") else 1


if __name__ == "__main__":
    raise SystemExit(main())

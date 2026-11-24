"""Compare final-layer FFN down kernels on the same eight captured activations."""

import argparse
import json
from pathlib import Path
import subprocess
from tempfile import TemporaryDirectory

import gguf
import numpy as np
from onnx import TensorProto, helper, numpy_helper

from compare_capture import compare
from prepare_decoder_layer import MAX_NATIVE_STAGE_L2
from prepare_ffn import FfnGraph
from projection import save_onnx_graph
from replay_target import compare_codes, load_hidden, run_htp, score_logits, write_json


VARIANTS = ("q8-batch8", "q8-batch4", "q8-single", "f32-batch")


def run_native(server, fixture, directory, device, variant):
    log_path = directory / f"{variant}.log"
    with log_path.open("wb") as log:
        try:
            process = subprocess.run([str(server), "--verify-ffn-down", str(fixture), device, variant],
                                     stdout=log, stderr=subprocess.STDOUT, timeout=30, check=False)
        except subprocess.TimeoutExpired as error:
            raise RuntimeError("native projection timed out after 30s") from error
    if process.returncode:
        with log_path.open("rb") as log:
            log.seek(max(0, log_path.stat().st_size - 1024))
            tail = log.read().decode("utf-8", errors="replace").rstrip().splitlines()
        detail = tail[-1][-200:] if tail else f"see {log_path.name}"
        raise RuntimeError(f"native projection exit {process.returncode}: {detail}")
    return load_hidden(fixture / f"{variant}.f32")


def run_qdq(x, weights, directory):
    graph = FfnGraph()
    feed, x_qdq = graph.activation("x", x, input_tensor=True)
    expected, dequantized = graph.activation("y", graph.project("y", "x", x_qdq, weights), output_tensor=True)
    model = helper.make_graph(
        graph.nodes, "verify_ffn_down",
        [helper.make_tensor_value_info("x_u16", TensorProto.UINT16, feed.shape)],
        [helper.make_tensor_value_info("y_u16", TensorProto.UINT16, expected.shape)],
        [numpy_helper.from_array(value, name) for name, value in graph.initializers.items()],
    )
    with TemporaryDirectory(prefix="htp-", dir=directory) as temporary:
        model_path = Path(temporary) / "ffn_down_qdq.onnx"
        save_onnx_graph(model, model_path)
        codes, median, events, error = run_htp(model_path, directory / "ffn-down-htp", {"x_u16": feed}, 45)
    result = {"error": error, "qaairt_execute_events": events, "host_median_ms": median}
    if codes is None:
        return result, None, dequantized
    result["htp_vs_qdq_reference"] = compare_codes(codes, expected, "htp")
    actual = (codes.astype(np.float32) - 32768) * float(graph.initializers["y_scale"])
    return result, actual, dequantized


def run(args):
    directory = args.output.resolve()
    directory.mkdir(parents=True, exist_ok=False)
    manifest = json.loads((args.capture / "capture.json").read_text(encoding="utf-8"))
    target = gguf.GGUFReader(args.target)
    layer = int(target.get_field("qwen3vl.block_count").contents()) - 1
    if manifest["layer_count"] != layer + 1:
        raise ValueError("capture is missing final layer")
    folder = args.capture / f"layer-{layer}"
    x = np.fromfile(folder / "ffn_swiglu.f32", dtype="<f4").reshape(8, 6144)
    if not np.isfinite(x).all():
        raise ValueError("nonfinite captured SwiGLU")
    captured = load_hidden(folder / "ffn_out.f32")
    residual = load_hidden(folder / "ffn_inp.f32")
    native = load_hidden(folder / "layer_out.f32")
    if not np.array_equal(residual + captured, native):
        raise ValueError("captured final FFN residual does not match the native layer output")
    logits = np.fromfile(args.capture / "target_logits.f32", dtype="<f4").reshape(8, manifest["logit_columns"])
    if not np.isfinite(logits).all():
        raise ValueError("nonfinite captured logits")
    weight = next(item for item in target.tensors if item.name == f"blk.{layer}.ffn_down.weight")
    if weight.tensor_type != gguf.GGMLQuantizationType.Q8_0 or tuple(weight.shape) != (6144, 2048):
        raise ValueError("unexpected final FFN down weight shape or type")
    weights = gguf.dequantize(weight.data, weight.tensor_type)
    dense = x @ weights.T
    rounded_x = x.astype(np.float16).astype(np.float32)
    report = {"capture": str(args.capture), "device": args.device, "layer": layer,
              "dense_vs_captured": compare(dense, captured), "fp16_input_vs_dense": compare(rounded_x @ weights.T, dense),
              "variants": {}, "last_stage": "native projection", "passed": False}
    report_path = directory / "ffn_down_report.json"
    write_json(report_path, report)
    states = {"dense": residual + dense}
    with TemporaryDirectory(prefix="native-", dir=directory) as temporary:
        fixture = Path(temporary)
        x.tofile(fixture / "swiglu.f32")
        weight.data.tofile(fixture / "weight.q8")
        weights.astype("<f4", copy=False).tofile(fixture / "weight.f32")
        for variant in VARIANTS:
            report["last_stage"] = variant
            write_json(report_path, report)
            try:
                actual = run_native(args.server, fixture, directory, args.device, variant)
                report["variants"][variant] = {"vs_dense": compare(actual, dense), "vs_captured": compare(actual, captured)}
                states[variant] = residual + actual
            except (OSError, RuntimeError, ValueError) as error:
                report["variants"][variant] = {"error": str(error)}
            write_json(report_path, report)

    if not args.skip_htp:
        report["last_stage"] = "HTP projection"
        write_json(report_path, report)
        try:
            htp, actual, qdq = run_qdq(x, weights, directory)
            htp["qdq_vs_dense"] = compare(qdq, dense)
            if actual is not None:
                htp.update(vs_dense=compare(actual, dense), vs_captured=compare(actual, captured))
                states["htp"] = residual + actual
        except (OSError, RuntimeError, ValueError) as error:
            htp = {"error": str(error)}
        report["htp"] = htp

    report["last_stage"] = "host logits"
    write_json(report_path, report)
    _, report["logits"] = score_logits(target, logits, states)
    report["matching_native_variants"] = [
        name for name, row in report["variants"].items() if "vs_dense" in row and
        row["vs_dense"]["relative_l2_error"] <= MAX_NATIVE_STAGE_L2 and report["logits"][name]["matches"] == 8
    ]
    report["native_reference_passed"] = report["dense_vs_captured"]["relative_l2_error"] <= MAX_NATIVE_STAGE_L2
    report["passed"] = (report["native_reference_passed"] and
                        "q8-batch8" in report["matching_native_variants"] and
                        (args.skip_htp or (not htp.get("error") and htp["qaairt_execute_events"] > 0 and
                                           htp["htp_vs_qdq_reference"]["accuracy_passed"] and
                                           report["logits"]["htp"]["matches"] == 8)))
    report["last_stage"] = "complete"
    write_json(report_path, report)
    return report["passed"]


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("capture", "target", "server", "output"):
        parser.add_argument(f"--{name}", required=True, type=Path)
    parser.add_argument("--device", default="GPUOpenCL")
    parser.add_argument("--skip-htp", action="store_true")
    raise SystemExit(0 if run(parser.parse_args()) else 1)

"""Replay fixed eight-position Qwen3-ASR FFN and attention graphs through QNN HTP."""

import argparse
import json
import platform
import time
from functools import partial
from pathlib import Path

import numpy as np
import onnx
import onnxruntime as ort
from onnx import TensorProto, helper, numpy_helper

from compare_capture import compare


INPUT_SHAPE = (8, 2048)
WEIGHT_SHAPE = (2048, 6144)
QNN_PROVIDER = "QNNExecutionProvider"
MAX_ERROR_STEPS = 2
FULL_FFN_MAX_RELATIVE_L2 = 0.001
FULL_FFN_MAX_ERROR_OF_PEAK = 0.005
ATTENTION_MAX_RELATIVE_L2 = {"cpu": 0.0025, "htp": 0.005}
ATTENTION_MAX_ERROR_OF_PEAK = {"cpu": 0.01, "htp": 0.02}


def make_fixture(path, activation_multiplier=1):
    rng = np.random.default_rng(17)
    activation = rng.integers(-5, 6, INPUT_SHAPE, dtype=np.int16)
    weight = rng.integers(-7, 8, WEIGHT_SHAPE, dtype=np.int8)
    feed = (activation.astype(np.int32) * activation_multiplier + 32768).astype(np.uint16)
    # Scales 1/128, 1/64 and 1/1024 give an output quantum of eight accumulator units.
    accum = activation.astype(np.int32) @ weight.astype(np.int32)
    expected = (np.rint(accum / 8).astype(np.int32) + 32768).astype(np.uint16)
    initializers = {
        "w_u8": (weight.astype(np.int16) + 128).astype(np.uint8),
        "x_scale": np.array(1 / (128 * activation_multiplier), dtype=np.float32),
        "w_scale": np.array(1 / 64, dtype=np.float32),
        "y_scale": np.array(1 / 1024, dtype=np.float32),
        "x_zero": np.array(32768, dtype=np.uint16),
        "w_zero": np.array(128, dtype=np.uint8),
        "y_zero": np.array(32768, dtype=np.uint16),
    }
    write_projection(path, initializers)
    return feed, expected


def write_projection(path, initializers):
    graph = helper.make_graph(
        [
            helper.make_node("DequantizeLinear", ["x_u16", "x_scale", "x_zero"], ["x"], name="ActivationDQ"),
            helper.make_node("DequantizeLinear", ["w_u8", "w_scale", "w_zero"], ["w"], name="WeightDQ", axis=1),
            helper.make_node("MatMul", ["x", "w"], ["y"], name="FFNProjection"),
            helper.make_node("QuantizeLinear", ["y", "y_scale", "y_zero"], ["y_u16"], name="OutputQ"),
        ],
        "verify_projection",
        [helper.make_tensor_value_info("x_u16", TensorProto.UINT16, INPUT_SHAPE)],
        [helper.make_tensor_value_info("y_u16", TensorProto.UINT16, (INPUT_SHAPE[0], WEIGHT_SHAPE[1]))],
        [numpy_helper.from_array(value, name) for name, value in initializers.items()],
    )
    save_onnx_graph(graph, path)


def save_onnx_graph(graph, path, *, opset=21):
    model = helper.make_model(graph, opset_imports=[helper.make_opsetid("", opset)], ir_version=10)
    onnx.checker.check_model(model, full_check=True)
    onnx.save_model(model, path)


def compare_output(actual, expected, *, full_ffn_htp=False):
    if actual.dtype != np.uint16 or actual.shape != expected.shape:
        raise RuntimeError(f"unexpected output: {actual.dtype}, {actual.shape}")
    actual_i32 = actual.astype(np.int32)
    expected_i32 = expected.astype(np.int32)
    error = actual_i32 - expected_i32
    absolute_error = np.abs(error)
    worst = np.unravel_index(absolute_error.argmax(), absolute_error.shape)
    max_error = int(absolute_error[worst])
    signal = expected_i32 - 32768
    relative_l2 = float(np.linalg.norm(error) / max(1, np.linalg.norm(signal)))
    relative_to_peak = max_error / max(1, int(np.abs(signal).max()))
    accuracy_passed = max_error <= MAX_ERROR_STEPS
    if full_ffn_htp:
        # Rounding and sigmoid approximation can accumulate across the complete FFN.
        accuracy_passed = (relative_l2 <= FULL_FFN_MAX_RELATIVE_L2 and
                           relative_to_peak <= FULL_FFN_MAX_ERROR_OF_PEAK)
    return {
        "accuracy_passed": accuracy_passed,
        "relative_l2_error": relative_l2,
        "max_error_fraction_of_reference_peak": relative_to_peak,
        "max_error_quantization_steps": max_error,
        "p95_error_quantization_steps": float(np.percentile(absolute_error, 95)),
        "mean_signed_error_quantization_steps": float(error.mean()),
        "output_count_outside_tolerance": int(np.count_nonzero(absolute_error > MAX_ERROR_STEPS)),
        "output_count": int(actual.size),
        "actual_output_range": [int(actual.min()), int(actual.max())],
        "expected_output_range": [int(expected.min()), int(expected.max())],
        "actual_output_code_stride": int(np.gcd.reduce((actual_i32 - actual_i32.min()).ravel())),
        "worst_output_index": [int(i) for i in worst],
        "worst_expected_code": int(expected[worst]),
        "worst_actual_code": int(actual[worst]),
    }


def compare_attention_output(actual, expected, *, backend):
    if actual.shape != expected.shape or actual.dtype != np.float16 or not np.isfinite(actual).all():
        raise RuntimeError(f"invalid attention output: {actual.dtype}, {actual.shape}")
    peak = float(np.abs(expected).max())
    if not np.isfinite(expected).all() or peak == 0:
        raise RuntimeError("invalid attention reference")
    comparison = compare(actual, expected.astype(np.float32))
    max_error_of_peak = comparison["max_abs_error"] / peak
    return {
        **comparison,
        "max_error_fraction_of_reference_peak": max_error_of_peak,
        "accuracy_passed": (comparison["relative_l2_error"] <= ATTENTION_MAX_RELATIVE_L2[backend] and
                            max_error_of_peak <= ATTENTION_MAX_ERROR_OF_PEAK[backend]),
    }


def benchmark(args):
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    # Use more of A16's code range while keeping the exact same real-valued input.
    multiplier = 4096 if args.variant == "wide-a16" else 1
    kind = "projection"
    if args.replay:
        model = args.replay / "verify_projection.onnx"
        with np.load(args.replay / "input_and_reference.npz", allow_pickle=False) as fixture:
            if "replay_kind" in fixture:
                kind = fixture["replay_kind"].item()
            inputs = ({name: fixture[name] for name in ("Q", "K", "V", "attn_mask")} if kind == "attention"
                      else {"x_u16": fixture["feed"]})
            expected = fixture["expected"]
    else:
        model = output / "verify_projection.onnx"
        feed, expected = make_fixture(model, multiplier)
        inputs = {"x_u16": feed}
    full_ffn = kind == "full-ffn"
    attention = kind == "attention"
    options = ort.SessionOptions()
    run_options = ort.RunOptions()
    qnn_version = None
    if args.backend == "htp":
        import onnxruntime_qnn as qnn

        qnn_version = qnn.__version__
        ort.register_execution_provider_library(QNN_PROVIDER, qnn.get_library_path())

    session = devices = None
    try:
        if args.backend == "htp":
            devices = [device for device in ort.get_ep_devices() if device.ep_name == QNN_PROVIDER]
            if not devices:
                raise RuntimeError("QNN execution provider did not expose a device")
            options.add_session_config_entry("session.disable_cpu_ep_fallback", "1")
            provider_options = {
                "backend_path": qnn.get_qnn_htp_path(),
                "dump_json_qnn_graph": "1",
                "json_qnn_graph_dir": str(output),
            }
            if args.variant == "lut-off":
                provider_options["enable_htp_matmul_lut"] = "0"
            options.add_provider_for_devices(devices, provider_options)
            options.enable_profiling = True
            options.profile_file_prefix = str(output / "ort_profile")
            run_options.add_run_config_entry("qnn.perf_mode", "burst")

        start = time.perf_counter()
        providers = ["CPUExecutionProvider"] if args.backend == "cpu" else None
        session = ort.InferenceSession(str(model), sess_options=options, providers=providers, enable_fallback=False)
        init_ms = (time.perf_counter() - start) * 1000
        if args.backend == "htp" and QNN_PROVIDER not in session.get_providers():
            raise RuntimeError(f"QNN provider was not selected: {session.get_providers()}")

        actual, = session.run(None, inputs, run_options)
        full_ffn_htp = full_ffn and args.backend == "htp"
        compare_run = (partial(compare_attention_output, backend=args.backend) if attention else
                       partial(compare_output, full_ffn_htp=full_ffn_htp))
        comparison = compare_run(actual, expected)
        if args.replay:
            np.save(output / ("actual_f16.npy" if attention else "actual_u16.npy"), actual, allow_pickle=False)
        cpu_comparison = None
        if args.cpu_output:
            cpu_output = np.load(args.cpu_output, allow_pickle=False)
            cpu_comparison = compare_run(actual, cpu_output)
            comparison["accuracy_passed"] &= cpu_comparison["accuracy_passed"]
        elapsed_ms = []
        if comparison["accuracy_passed"]:
            for _ in range(args.warmup):
                session.run(None, inputs, run_options)
            for _ in range(args.runs):
                start = time.perf_counter()
                session.run(None, inputs, run_options)
                elapsed_ms.append((time.perf_counter() - start) * 1000)

        profile_path = None
        htp_events = None
        if args.backend == "htp":
            profile_path = Path(session.end_profiling())
            profile = json.loads(profile_path.read_text(encoding="utf-8"))
            htp_events = sum(
                event.get("qnn_operation") == "execute" and event.get("qnn_timing_source") == "BACKEND"
                for event in (entry.get("args") or {} for entry in profile)
            )
        result = {
            "backend": args.backend,
            "variant": args.variant,
            "onnxruntime": ort.__version__,
            "onnxruntime_qnn": qnn_version,
            "input_shape": next(iter(inputs.values())).shape,
            "output_shape": actual.shape,
            "weight_shape": WEIGHT_SHAPE if kind == "projection" else None,
            "weight_shapes": (WEIGHT_SHAPE, WEIGHT_SHAPE, WEIGHT_SHAPE[::-1]) if full_ffn else None,
            "replay_kind": kind,
            "providers": session.get_providers(),
            "activation_code_multiplier": None if args.replay else multiplier,
            "cpu_comparison": cpu_comparison,
            "max_allowed_error_quantization_steps": None if full_ffn_htp or attention else MAX_ERROR_STEPS,
            "max_allowed_relative_l2": (ATTENTION_MAX_RELATIVE_L2[args.backend] if attention else
                                         FULL_FFN_MAX_RELATIVE_L2 if full_ffn_htp else None),
            "max_allowed_error_of_peak": (ATTENTION_MAX_ERROR_OF_PEAK[args.backend] if attention else
                                           FULL_FFN_MAX_ERROR_OF_PEAK if full_ffn_htp else None),
            **comparison,
            "session_init_ms": init_ms,
            "host_median_ms": float(np.median(elapsed_ms)) if elapsed_ms else None,
            "host_p95_ms": float(np.percentile(elapsed_ms, 95)) if elapsed_ms else None,
            "timed_runs": len(elapsed_ms),
            "qnn_backend_execute_events": htp_events,
            "ort_profile": str(profile_path) if profile_path else None,
        }
        # Flush the result before destroying native objects, which may fail during teardown.
        text = json.dumps(result, indent=2)
        report_tmp = output / "projection_probe.json.tmp"
        report_tmp.write_text(text + "\n", encoding="utf-8")
        report_tmp.replace(output / "projection_probe.json")
        print(text, flush=True)
        return result
    finally:
        del session, options, devices
        if args.backend == "htp":
            ort.unregister_execution_provider_library(QNN_PROVIDER)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--backend", choices=("cpu", "htp"), default="htp")
    parser.add_argument("--variant", choices=("default", "lut-off", "wide-a16"), default="default")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--replay", type=Path, help="Prepared real capture QDQ graph and reference")
    parser.add_argument("--cpu-output", type=Path, help="CPU output from the same replay graph")
    parser.add_argument("--warmup", type=int, default=5)
    parser.add_argument("--runs", type=int, default=30)
    args = parser.parse_args()
    if args.warmup < 0 or args.runs < 1:
        parser.error("warmup must be nonnegative and runs must be positive")
    if args.backend == "cpu" and args.variant == "lut-off":
        parser.error("lut-off is an HTP option")
    if args.replay and args.variant != "default":
        parser.error("replay takes its encoding from the prepared graph")
    if args.cpu_output and (not args.replay or args.backend != "htp"):
        parser.error("--cpu-output requires an HTP replay")
    if args.backend == "htp" and (platform.system() != "Windows" or platform.machine().lower() not in ("arm64", "aarch64")):
        parser.error("HTP requires Windows ARM64 Python")
    result = benchmark(args)
    if not result["accuracy_passed"] or (args.backend == "htp" and not result["qnn_backend_execute_events"]):
        raise SystemExit(1)


if __name__ == "__main__":
    main()

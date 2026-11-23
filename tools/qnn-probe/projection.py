"""Probe a fixed eight-position Qwen3-ASR FFN projection shape through QNN HTP."""

import argparse
import json
import platform
import time
from pathlib import Path

import numpy as np
import onnx
import onnxruntime as ort
from onnx import TensorProto, helper, numpy_helper


INPUT_SHAPE = (8, 2048)
WEIGHT_SHAPE = (2048, 6144)
QNN_PROVIDER = "QNNExecutionProvider"


def make_fixture(path):
    rng = np.random.default_rng(17)
    activation = rng.integers(-5, 6, INPUT_SHAPE, dtype=np.int16)
    weight = rng.integers(-7, 8, WEIGHT_SHAPE, dtype=np.int8)
    feed = (activation.astype(np.int32) + 32768).astype(np.uint16)
    # Scales 1/128, 1/64 and 1/1024 give an output quantum of eight accumulator units.
    accum = activation.astype(np.int32) @ weight.astype(np.int32)
    expected = (np.rint(accum / 8).astype(np.int32) + 32768).astype(np.uint16)
    initializers = {
        "w_u8": (weight.astype(np.int16) + 128).astype(np.uint8),
        "x_scale": np.array(1 / 128, dtype=np.float32),
        "w_scale": np.array(1 / 64, dtype=np.float32),
        "y_scale": np.array(1 / 1024, dtype=np.float32),
        "x_zero": np.array(32768, dtype=np.uint16),
        "w_zero": np.array(128, dtype=np.uint8),
        "y_zero": np.array(32768, dtype=np.uint16),
    }
    graph = helper.make_graph(
        [
            helper.make_node("DequantizeLinear", ["x_u16", "x_scale", "x_zero"], ["x"], name="ActivationDQ"),
            helper.make_node("DequantizeLinear", ["w_u8", "w_scale", "w_zero"], ["w"], name="WeightDQ"),
            helper.make_node("MatMul", ["x", "w"], ["y"], name="FFNProjection"),
            helper.make_node("QuantizeLinear", ["y", "y_scale", "y_zero"], ["y_u16"], name="OutputQ"),
        ],
        "verify_projection",
        [helper.make_tensor_value_info("x_u16", TensorProto.UINT16, INPUT_SHAPE)],
        [helper.make_tensor_value_info("y_u16", TensorProto.UINT16, (INPUT_SHAPE[0], WEIGHT_SHAPE[1]))],
        [numpy_helper.from_array(value, name) for name, value in initializers.items()],
    )
    model = helper.make_model(graph, opset_imports=[helper.make_opsetid("", 21)], ir_version=10)
    onnx.checker.check_model(model, full_check=True)
    onnx.save_model(model, path)
    return feed, expected


def check_output(session, feed, expected, run_options):
    actual, = session.run(None, {"x_u16": feed}, run_options)
    if actual.dtype != np.uint16 or actual.shape != expected.shape:
        raise RuntimeError(f"unexpected output: {actual.dtype}, {actual.shape}")
    max_error = int(np.max(np.abs(actual.astype(np.int32) - expected.astype(np.int32))))
    if max_error > 2:
        raise RuntimeError(f"projection output differs by up to {max_error} quantization steps")
    return max_error


def benchmark(args):
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    model = output / "verify_projection.onnx"
    feed, expected = make_fixture(model)
    options = ort.SessionOptions()
    run_options = ort.RunOptions()
    qnn_version = None
    if args.backend == "htp":
        import onnxruntime_qnn as qnn

        qnn_version = qnn.__version__
        ort.register_execution_provider_library(QNN_PROVIDER, qnn.get_library_path())

    session = None
    try:
        if args.backend == "htp":
            devices = [device for device in ort.get_ep_devices() if device.ep_name == QNN_PROVIDER]
            if not devices:
                raise RuntimeError("QNN execution provider did not expose a device")
            options.add_session_config_entry("session.disable_cpu_ep_fallback", "1")
            options.add_provider_for_devices(devices, {"backend_path": qnn.get_qnn_htp_path()})
            options.enable_profiling = True
            options.profile_file_prefix = str(output / "ort_profile")
            run_options.add_run_config_entry("qnn.perf_mode", "burst")

        start = time.perf_counter()
        providers = ["CPUExecutionProvider"] if args.backend == "cpu" else None
        session = ort.InferenceSession(str(model), sess_options=options, providers=providers)
        init_ms = (time.perf_counter() - start) * 1000
        session.disable_fallback()
        if args.backend == "htp" and QNN_PROVIDER not in session.get_providers():
            raise RuntimeError(f"QNN provider was not selected: {session.get_providers()}")

        max_error = check_output(session, feed, expected, run_options)
        inputs = {"x_u16": feed}
        for _ in range(args.warmup):
            session.run(None, inputs, run_options)
        elapsed_ms = []
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
            if not htp_events:
                raise RuntimeError(f"no QAIRT backend execute events in {profile_path}")

        return {
            "backend": args.backend,
            "onnxruntime": ort.__version__,
            "onnxruntime_qnn": qnn_version,
            "input_shape": INPUT_SHAPE,
            "weight_shape": WEIGHT_SHAPE,
            "providers": session.get_providers(),
            "max_error_quantization_steps": max_error,
            "session_init_ms": init_ms,
            "host_median_ms": float(np.median(elapsed_ms)),
            "host_p95_ms": float(np.percentile(elapsed_ms, 95)),
            "timed_runs": len(elapsed_ms),
            "qnn_backend_execute_events": htp_events,
            "ort_profile": str(profile_path) if profile_path else None,
        }
    finally:
        del session
        if args.backend == "htp":
            ort.unregister_execution_provider_library(QNN_PROVIDER)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--backend", choices=("cpu", "htp"), default="htp")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--warmup", type=int, default=5)
    parser.add_argument("--runs", type=int, default=30)
    args = parser.parse_args()
    if args.warmup < 0 or args.runs < 1:
        parser.error("warmup must be nonnegative and runs must be positive")
    if args.backend == "htp" and (platform.system() != "Windows" or platform.machine().lower() not in ("arm64", "aarch64")):
        parser.error("HTP requires Windows ARM64 Python")
    result = benchmark(args)
    text = json.dumps(result, indent=2)
    (args.output / "projection_probe.json").write_text(text + "\n", encoding="utf-8")
    print(text)


if __name__ == "__main__":
    main()

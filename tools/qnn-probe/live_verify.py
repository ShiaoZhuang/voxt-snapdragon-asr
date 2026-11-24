"""Calibrate and serve the eight-position Target graph for a local Voxt process."""

import argparse
from copy import deepcopy
import json
from pathlib import Path
import time

import gguf
import numpy as np
import onnx
from onnx import TensorProto, compose, helper
import onnxruntime as ort

from prepare_decoder_layer import normalize, prepare, rotary_tables_for_positions
from projection import QNN_PROVIDER, htp_execute_events, htp_session_options
from replay_target import read_head, write_json


LAYERS, ROWS, WIDTH, VOCAB = 28, 8, 2048, 151936


def calibrate(target, aux, capture, model_path, *, cpu_test=False):
    inputs, outputs, nodes, initializers = [], [], [], []
    previous = "residual"
    for layer in range(LAYERS):
        folder = capture / f"layer-{layer}" if layer else capture
        graph, feeds, _ = prepare(folder, target, None, full=True, layer=layer, activation_code_limit=24576,
                                  allow_reference_mismatch=True, live=True, live_cpu=cpu_test)
        if layer == 0:
            cache_shape = feeds["past_key"].shape
            inputs += [deepcopy(item) for item in graph.input
                       if item.name in {"residual", "attn_mask", "rope_cos", "rope_sin"}]
        if feeds["past_key"].shape != cache_shape:
            raise ValueError("inconsistent calibration cache shapes")
        prefix = f"L{layer}_"
        shared = {prefix + name: name for name in ("attn_mask", "rope_cos", "rope_sin")}
        shared[prefix + "residual"] = previous
        compose.add_prefix_graph(graph, prefix, inplace=True)
        for node in graph.node:
            for i, name in enumerate(node.input):
                node.input[i] = shared.get(name, name)
        inputs += [item for item in graph.input if item.name.endswith(("_past_key", "_past_value"))]
        outputs += list(graph.output[1:])
        next_state = f"hidden_{layer + 1}"
        nodes.extend(graph.node)
        nodes.append(helper.make_node("DequantizeLinear", [prefix + name for name in ("y_u16", "y_scale", "y_zero")],
                                      [prefix + "y_dq"]))
        nodes.append(helper.make_node("Cast", [prefix + "y_dq"], [next_state], to=TensorProto.FLOAT16))
        initializers.extend(graph.initializer)
        previous = next_state
        print(f"Calibrated layer {layer + 1}/{LAYERS}", flush=True)
    outputs += [helper.make_tensor_value_info(f"hidden_{i}", TensorProto.FLOAT16, [ROWS, WIDTH])
                for i in aux + [LAYERS]]
    model = helper.make_model(helper.make_graph(nodes, "voxt_target_verify", inputs, outputs, initializers),
                              opset_imports=[helper.make_opsetid("", 23)], ir_version=10)
    onnx.save_model(model, model_path, save_as_external_data=True, all_tensors_to_one_file=True,
                    location=model_path.name + ".data")
    onnx.checker.check_model(str(model_path))
    return int(cache_shape[2])


def read_request(path, history_capacity, embedding, rope):
    with path.open("rb") as request:
        n = int(np.fromfile(request, "<i4", 1)[0])
        if not 0 <= n <= history_capacity:
            raise ValueError(f"history length {n} exceeds capacity {history_capacity}")
        tokens = np.fromfile(request, "<i4", ROWS)
        positions = np.fromfile(request, "<i4", 4 * ROWS).reshape(4, ROWS)
        if len(tokens) != ROWS or np.any(tokens < 0) or np.any(tokens >= VOCAB):
            raise ValueError("invalid verification token ids")
        residual = gguf.dequantize(embedding.data[tokens], embedding.tensor_type).astype(np.float16)
        cos, sin = rotary_tables_for_positions(rope, positions)
        mask = np.full((1, 1, ROWS, history_capacity + ROWS), -np.inf, dtype=np.float16)
        mask[..., :n] = 0
        for row in range(ROWS):
            mask[..., row, history_capacity:history_capacity + row + 1] = 0
        feeds = {"residual": residual, "attn_mask": mask,
                 "rope_cos": np.concatenate((cos, cos), axis=-1).astype(np.float16),
                 "rope_sin": np.concatenate((-sin, sin), axis=-1).astype(np.float16)}
        for layer in range(LAYERS):
            for kind in ("key", "value"):
                kv = np.zeros((1, 8, history_capacity, 128), dtype=np.float16)
                kv[:, :, :n, :] = np.fromfile(request, "<f2", n * 1024).reshape(n, 8, 128).swapaxes(0, 1)
                feeds[f"L{layer}_past_{kind}"] = kv
        if request.read(1):
            raise ValueError("unexpected verification request length")
    return feeds


def serve(args):
    folder = args.directory
    folder.mkdir(parents=True, exist_ok=True)
    target = gguf.GGUFReader(args.target)
    embedding = next(t for t in target.tensors if t.name == "token_embd.weight")
    head, norm, epsilon = read_head(target, VOCAB)
    weights = gguf.dequantize(head.data, head.tensor_type)
    rope = json.loads((args.capture / "attention.json").read_text())["rope"]
    aux = list(gguf.GGUFReader(args.draft).get_field("dflash.target_layers").contents())
    if aux != [2, 14, 25]:
        raise ValueError(f"unsupported DFlash auxiliary layers: {aux}")
    model = folder / "target-verify.onnx"
    capacity = calibrate(target, aux, args.capture, model, cpu_test=args.cpu_test)
    print("Initializing verification runtime", flush=True)
    if args.cpu_test:
        options = ort.SessionOptions()
        options.intra_op_num_threads = 4
        session = ort.InferenceSession(str(model), sess_options=options, providers=["CPUExecutionProvider"])
        run_options = None
    else:
        import onnxruntime_qnn as qnn
        ort.register_execution_provider_library(QNN_PROVIDER, qnn.get_library_path())
        options, run_options, _ = htp_session_options(qnn, folder / "profile")
        session = ort.InferenceSession(str(model), sess_options=options, enable_fallback=False)
        if QNN_PROVIDER not in session.get_providers():
            raise RuntimeError("QNN HTP provider missing from the verification session")
    write_json(folder / "ready.json", {"history_capacity": capacity})
    count = 0
    try:
        while not (folder / "stop").exists():
            request = folder / "request.bin"
            if not request.exists():
                time.sleep(0.002)
                continue
            feeds = read_request(request, capacity, embedding, rope)
            request.unlink()
            names = [f"L{i}_{kind}" for i in range(LAYERS) for kind in ("K", "V")] + [
                f"hidden_{i}" for i in aux + [LAYERS]]
            start = time.perf_counter()
            values = session.run(names, feeds, run_options)
            print(f"Round {count + 1} graph: {(time.perf_counter() - start) * 1000:.2f} ms", flush=True)
            logits = normalize(values[-1].astype(np.float32), norm, epsilon) @ weights.T
            if any(not np.isfinite(x).all() for x in [*values, logits]):
                raise ValueError("nonfinite live verifier output")
            stage = folder / "response.tmp"
            with stage.open("wb") as response:
                for kv in values[:LAYERS * 2]:
                    kv.swapaxes(1, 2).astype("<f2", copy=False).tofile(response)
                for hidden in values[LAYERS * 2:-1]:
                    hidden.astype("<f4").tofile(response)
                logits.astype("<f4", copy=False).tofile(response)
            stage.replace(folder / "response.bin")
            count += 1
    finally:
        events = 0 if args.cpu_test else htp_execute_events(session.end_profiling())
        write_json(folder / "worker_report.json", {"rounds": count, "qaairt_execute_events": events})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for arg in ("target", "draft", "capture", "directory"):
        parser.add_argument(f"--{arg}", type=Path, required=True)
    parser.add_argument("--cpu-test", action="store_true", help="developer test, never reports HTP execution")
    args = parser.parse_args()
    try:
        serve(args)
    except Exception as error:
        write_json(args.directory / "error.json", {"error": str(error)})
        raise


if __name__ == "__main__":
    main()

"""Prepare a full layer-0 SwiGLU FFN replay from a real DFlash verification batch."""

import argparse
import json
from pathlib import Path

import numpy as np
from onnx import TensorProto, helper, numpy_helper

from compare_capture import compare, load_weights, read_capture, symmetric_codes
from projection import save_onnx_graph


class FfnGraph:
    def __init__(self):
        self.nodes = []
        self.initializers = {}

    def node(self, op, inputs, output, **attributes):
        self.nodes.append(helper.make_node(op, inputs, [output], name=output, **attributes))

    def activation(self, name, values, *, input_tensor=False, output_tensor=False, sigmoid=False):
        scale = np.array(1 / 65536 if sigmoid else np.max(np.abs(values)) / 32000, dtype=np.float32)
        zero = 0 if sigmoid else 32768
        if not np.isfinite(scale) or scale <= 0:
            raise ValueError(f"invalid activation scale for {name}")
        tensor = f"{name}_u16"
        params = [f"{name}_scale", f"{name}_zero"]
        self.initializers[params[0]] = scale
        self.initializers[params[1]] = np.array(zero, dtype=np.uint16)
        if not input_tensor:
            self.node("QuantizeLinear", [name, *params], tensor)
        if not output_tensor:
            self.node("DequantizeLinear", [tensor, *params], f"{name}_dq")
        codes = np.clip(np.rint(values.astype(np.float64) / float(scale)) + zero, 0, 65535).astype(np.uint16)
        return codes, (codes.astype(np.int32) - zero) * float(scale)

    def project(self, name, input_name, activation, weight):
        codes, scale = symmetric_codes(weight, 127, axis=1)
        qweight = f"{name}_u8_weight"
        qscale = f"{name}_weight_scale"
        qzero = f"{name}_weight_zero"
        dequantized = f"{name}_weight"
        self.initializers[qweight] = (codes.T + 128).astype(np.uint8)
        self.initializers[qscale] = scale.ravel()
        self.initializers[qzero] = np.full(weight.shape[0], 128, dtype=np.uint8)
        self.node("DequantizeLinear", [qweight, qscale, qzero], dequantized, axis=1)
        self.node("MatMul", [f"{input_name}_dq", dequantized], name)
        return activation @ (codes.T * scale.ravel())

    def save(self, path):
        shape = (8, 2048)
        graph = helper.make_graph(
            self.nodes, "verify_layer0_ffn",
            [helper.make_tensor_value_info("x_u16", TensorProto.UINT16, shape)],
            [helper.make_tensor_value_info("y_u16", TensorProto.UINT16, shape)],
            [numpy_helper.from_array(value, name) for name, value in self.initializers.items()],
        )
        save_onnx_graph(graph, path)


def sigmoid(values):
    return 1 / (1 + np.exp(-values))


def prepare(capture, target, output):
    x, native = read_capture(capture, full_ffn=True)
    w_up, w_gate, w_down = load_weights(target, ["up", "gate", "down"])
    gate_dense = x @ w_gate.T
    dense = (gate_dense * sigmoid(gate_dense) * (x @ w_up.T)) @ w_down.T

    graph = FfnGraph()
    feed, x_qdq = graph.activation("x", x, input_tensor=True)
    _, up = graph.activation("up", graph.project("up", "x", x_qdq, w_up))
    _, gate = graph.activation("gate", graph.project("gate", "x", x_qdq, w_gate))
    graph.node("Sigmoid", ["gate_dq"], "sigmoid")
    _, probability = graph.activation("sigmoid", sigmoid(gate), sigmoid=True)
    graph.node("Mul", ["gate_dq", "sigmoid_dq"], "silu")
    _, silu = graph.activation("silu", gate * probability)
    graph.node("Mul", ["silu_dq", "up_dq"], "swiglu")
    _, swiglu = graph.activation("swiglu", silu * up)
    expected, dequantized = graph.activation("y", graph.project("y", "swiglu", swiglu, w_down), output_tensor=True)

    output.mkdir(parents=True, exist_ok=False)
    graph.save(output / "verify_projection.onnx")
    np.savez(output / "input_and_reference.npz", feed=feed, expected=expected, replay_kind="full-ffn")
    report = {
        "dense_vs_native_capture": compare(dense, native),
        "qdq_vs_dense_q8_0": compare(dequantized, dense),
        "qdq_vs_native_capture": compare(dequantized, native),
        "activation_scale": float(graph.initializers["x_scale"]),
        "output_scale": float(graph.initializers["y_scale"]),
        "weight_scale_count": sum(weight.shape[0] for weight in (w_up, w_gate, w_down)),
    }
    text = json.dumps(report, indent=2) + "\n"
    (output / "preparation.json").write_text(text, encoding="utf-8")
    print(text, end="")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--capture", required=True, type=Path)
    parser.add_argument("--target", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    prepare(args.capture, args.target, args.output)


if __name__ == "__main__":
    main()

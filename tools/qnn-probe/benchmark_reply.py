"""Measure verifier response serialization and TCP delivery using a captured eight-position batch."""

import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
from pathlib import Path
import socket
import struct
from statistics import median
from time import perf_counter_ns

import numpy as np

from qnn_reply import AUX_LAYERS, LAYERS, ROWS, VOCAB, WIDTH, PackedReply, legacy_chunks, send_reply


def load_batch(capture):
    manifest = json.loads((capture / "capture.json").read_text(encoding="utf-8"))
    if (manifest["layer_count"] != LAYERS or manifest["logit_columns"] != VOCAB
            or len(manifest["tokens"]) != ROWS or manifest["input_shape"] != [ROWS, WIDTH]):
        raise ValueError(f"unexpected verification dimensions in {capture}")
    kv, hidden = [], []
    for layer in range(LAYERS):
        folder = capture / f"layer-{layer}" if layer else capture
        attention = json.loads((folder / "attention.json").read_text(encoding="utf-8"))
        for field in ("current_k", "current_v"):
            info = attention[field]
            if (info["shape"] != [1, ROWS, 8, 128] or info["dtype"] not in ("<f2", "<f4")
                    or info["file"] != f"{field}.bin"):
                raise ValueError(f"unexpected {field} metadata at layer {layer}")
            source = np.fromfile(folder / info["file"], info["dtype"]).reshape(info["shape"])
            # Native capture is row-major. ORT returns a contiguous head-major tensor.
            kv.append(np.ascontiguousarray(source.swapaxes(1, 2), dtype=np.float16))
        if layer in AUX_LAYERS:
            source = np.fromfile(folder / "attention_residual.f32", "<f4").reshape(ROWS, WIDTH)
            hidden.append(source.astype(np.float16))
    logits = np.fromfile(capture / "target_logits.f32", "<f4").reshape(ROWS, VOCAB)
    if any(not np.isfinite(tensor).all() for tensor in [*kv, *hidden, logits]):
        raise ValueError(f"nonfinite verification tensor in {capture}")
    return kv, hidden, logits


def receive_into(client, destination):
    remaining = memoryview(destination)
    while remaining:
        length = client.recv_into(remaining[:1 << 20])
        if not length:
            raise EOFError("incomplete loopback reply")
        remaining = remaining[length:]


def receive_reply(client, output):
    header = bytearray(4)
    receive_into(client, header)
    if struct.unpack("!I", header)[0] != len(output):
        raise ValueError("invalid reply frame size")
    receive_into(client, output)
    return perf_counter_ns()


def benchmark(batch, pairs):
    encoders = {"legacy": legacy_chunks, "packed": PackedReply().chunks}
    expected = b"".join(legacy_chunks(*batch))
    output = bytearray(len(expected))
    rows = []
    with socket.socket() as listener, ThreadPoolExecutor(max_workers=1) as receiver:
        listener.bind(("127.0.0.1", 0))
        listener.listen(1)
        listener.settimeout(10)
        # Two warmup pairs, then the same number of A/B and B/A pairs.
        for pair in range(-2, pairs):
            order = ("legacy", "packed") if pair % 2 == 0 else ("packed", "legacy")
            for mode in order:
                with socket.create_connection(listener.getsockname(), timeout=10) as client:
                    sender, _ = listener.accept()
                    with sender:
                        sender.settimeout(10)
                        received = receiver.submit(receive_reply, client, output)
                        start = perf_counter_ns()
                        chunks = encoders[mode](*batch)
                        packed = perf_counter_ns()
                        send_reply(sender, chunks)
                        sent = perf_counter_ns()
                        end = max(received.result(), sent)
                        if output != expected:
                            raise ValueError(f"{mode} differs from the reference payload in pair {pair}")
                        if pair >= 0:
                            rows.append({"pair": pair + 1, "mode": mode, "pack_ms": (packed - start) / 1e6,
                                         "send_ms": (sent - packed) / 1e6, "delivery_ms": (end - start) / 1e6,
                                         "body_sendall_calls": len(chunks)})
                        del chunks
    return rows, len(expected), hashlib.sha256(expected).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--capture", type=Path, required=True)
    parser.add_argument("--logs", type=Path, required=True)
    parser.add_argument("--pairs", type=int, default=12)
    args = parser.parse_args()
    if args.pairs < 2 or args.pairs % 2:
        parser.error("--pairs must be positive, even and at least two")
    rows, size, digest = benchmark(load_batch(args.capture), args.pairs)
    print(f"QNN reply | {args.pairs} matched pairs | captured worker reply pack + TCP loopback only | {size} body bytes each")
    for mode in ("legacy", "packed"):
        arm = [row for row in rows if row["mode"] == mode]
        print(f"QNN reply {mode} | {arm[0]['body_sendall_calls']} body sendall calls | "
              f"median pack {median(r['pack_ms'] for r in arm):.3f} ms | "
              f"send {median(r['send_ms'] for r in arm):.3f} ms | "
              f"pack through delivery {median(r['delivery_ms'] for r in arm):.3f} ms")
    by_pair = {(r["pair"], r["mode"]): r["delivery_ms"] for r in rows}
    deltas = [by_pair[i, "legacy"] - by_pair[i, "packed"] for i in range(1, args.pairs + 1)]
    print(f"QNN reply | median paired delivery saving {median(deltas):+.3f} ms | "
          f"packed faster in {sum(d > 0 for d in deltas)}/{len(deltas)}")
    args.logs.mkdir(parents=True, exist_ok=True)
    report = {"capture": str(args.capture.resolve()), "body_bytes": size, "body_sha256": digest,
              "scope": "workers' reply packing and loopback delivery of captured native tensors",
              "warmup_pairs": 2, "pairs": args.pairs, "runs": rows}
    (args.logs / "qnn-reply.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(f"PASS | all received payloads byte-identical | SHA-256 {digest}")


if __name__ == "__main__":
    main()

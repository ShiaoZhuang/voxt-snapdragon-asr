"""Wire encoding of the loopback-v1 eight-position verifier response."""

import struct

import numpy as np


LAYERS, ROWS, WIDTH, VOCAB = 28, 8, 2048, 151936
AUX_LAYERS = (2, 14, 25)


def legacy_chunks(kv, hidden, logits):
    chunks = [tensor.swapaxes(1, 2).astype("<f2", copy=False).tobytes() for tensor in kv]
    chunks.extend(tensor.astype("<f4").tobytes() for tensor in hidden)
    chunks.append(logits.astype("<f4", copy=False).tobytes())
    return chunks


class PackedReply:
    """One worker handles one client at a time. Reuse the prefix after sendall returns."""

    def __init__(self):
        kv_bytes = LAYERS * 2 * ROWS * 8 * 128 * 2
        aux_bytes = len(AUX_LAYERS) * ROWS * WIDTH * 4
        self.prefix = bytearray(kv_bytes + aux_bytes)
        self.kv = np.frombuffer(self.prefix, "<f2", kv_bytes // 2).reshape(LAYERS * 2, ROWS, 8, 128)
        self.aux = np.frombuffer(self.prefix, "<f4", offset=kv_bytes).reshape(len(AUX_LAYERS), ROWS, WIDTH)

    def chunks(self, kv, hidden, logits):
        if len(kv) != len(self.kv) or len(hidden) != len(self.aux):
            raise ValueError("incomplete verifier reply")
        for target, source in zip(self.kv, kv):
            target[:] = source[0].swapaxes(0, 1)
        for target, source in zip(self.aux, hidden):
            target[:] = source
        scores = np.ascontiguousarray(logits, dtype="<f4")
        return self.prefix, memoryview(scores).cast("B")


def send_reply(client, chunks):
    client.sendall(struct.pack("!I", sum(map(len, chunks))))
    for chunk in chunks:
        client.sendall(chunk)

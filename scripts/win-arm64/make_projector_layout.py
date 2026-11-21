#!/usr/bin/env python3
"""Emit the pinned BF16-to-FP16 projector layout for the native converter."""

import argparse
import base64
import json
from pathlib import Path

import gguf


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("reference", type=Path)
    args = parser.parse_args()
    source = gguf.GGUFReader(args.source)
    reference = gguf.GGUFReader(args.reference)
    ranges = []
    for before, after in zip(source.tensors, reference.tensors, strict=True):
        offset = before.data_offset - source.data_offset
        expected_type = (
            gguf.GGMLQuantizationType.F16
            if before.tensor_type == gguf.GGMLQuantizationType.BF16
            else before.tensor_type
        )
        if (
            before.name != after.name
            or before.n_bytes != after.n_bytes
            or offset != after.data_offset - reference.data_offset
            or expected_type != after.tensor_type
        ):
            raise ValueError(f"Tensor layout differs: {before.name}")
        if before.tensor_type == gguf.GGMLQuantizationType.BF16:
            ranges.append([offset, before.n_bytes])
    with args.reference.open("rb") as file:
        header = base64.b64encode(file.read(reference.data_offset)).decode("ascii")
    print(json.dumps({
        "source_data_offset": source.data_offset,
        "output_header": header,
        "bf16_ranges": sorted(ranges),
    }, indent=2))


if __name__ == "__main__":
    main()

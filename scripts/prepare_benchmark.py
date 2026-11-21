#!/usr/bin/env python3
"""Prepare a standalone Voxt Final-only benchmark from a pinned source archive."""

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile


def digest(path):
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--voxt-repo", type=Path, required=True)
    parser.add_argument("--destination", type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    lock = json.loads((root / "sources.lock.json").read_text())
    destination = args.destination.resolve()
    if destination.exists():
        parser.error(f"destination already exists: {destination}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    repo = args.voxt_repo.resolve()
    revision = lock["voxt"]["public_commit"]
    with tempfile.TemporaryDirectory(dir=destination.parent) as staging:
        checkout = Path(staging) / "source"
        checkout.mkdir()
        with tempfile.TemporaryFile() as archive:
            subprocess.run(
                ["git", "-C", str(repo), "archive", revision, "Voxt", "sglang_omni_mlx"],
                stdout=archive, check=True,
            )
            archive.seek(0)
            subprocess.run(["tar", "-xf", "-", "-C", str(checkout)], stdin=archive, check=True)
        with (root / "patches/voxt-mlx-baseline.patch").open("rb") as patch:
            subprocess.run(["patch", "-s", "-p1"], cwd=checkout, stdin=patch, check=True)
        for path, expected in lock["benchmark"].items():
            if digest(checkout / path) != expected:
                raise ValueError(f"benchmark SHA-256 mismatch: {path}")

        # Observe the exact final SSE payload that Voxt accepted. The parser,
        # request policy, and production source checkout are unchanged.
        client = checkout / "Voxt/internal/omni/final.go"
        source = client.read_text()
        marker = "\t\tif res != nil {\n\t\t\tdone = res\n"
        if source.count(marker) != 1:
            raise ValueError("cannot locate the pinned Voxt SSE observer point")
        client.write_text(source.replace(marker, marker + '\t\t\tl.s.rt.logf("debug", "benchmark_sse "+payload)\n'))
        driver = checkout / "Voxt/cmd/final-benchmark"
        driver.mkdir(parents=True)
        shutil.copyfile(root / "benchmark/final.go", driver / "main.go")
        checkout.rename(destination)


if __name__ == "__main__":
    main()

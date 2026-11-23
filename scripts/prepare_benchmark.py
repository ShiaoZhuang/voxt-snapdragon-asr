#!/usr/bin/env python3
"""Prepare a standalone Voxt Final-only benchmark from a pinned source archive."""

import argparse
import hashlib
import json
import os
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
    parser.add_argument("--runner-only", action="store_true", help="Prepare only the Go runner and its sources")
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
        paths = ["Voxt/internal", "Voxt/go.mod", "Voxt/go.sum"] if args.runner_only else ["Voxt", "sglang_omni_mlx"]
        archive = Path(staging) / "source.tar"
        subprocess.run(["git", "-C", str(repo), "archive", f"--output={archive}", revision, *paths], check=True)
        shutil.unpack_archive(archive, checkout)
        patch_args = ["--include=Voxt/internal/omni/*"] if args.runner_only else []
        subprocess.run(
            ["git", "apply", "--no-index", *patch_args, str(root / "patches/voxt-mlx-baseline.patch")],
            cwd=checkout, env={**os.environ, "GIT_CEILING_DIRECTORIES": staging}, check=True,
        )
        if not args.runner_only:
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
        with client.open("w", encoding="utf-8", newline="\n") as output:
            output.write(source.replace(marker, marker + '\t\t\tl.s.rt.logf("debug", "benchmark_sse "+payload)\n'))
        driver = checkout / "Voxt/cmd/final-benchmark"
        driver.mkdir(parents=True)
        shutil.copyfile(root / "benchmark/final.go", driver / "main.go")
        checkout.rename(destination)


if __name__ == "__main__":
    main()

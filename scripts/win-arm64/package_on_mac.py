#!/usr/bin/env python3
"""Assemble the offline Windows ARM64 verification directory."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]


def file_hash(path):
    with path.open("rb") as data:
        return hashlib.file_digest(data, "sha256").hexdigest()


def arm64_pe(path):
    with path.open("rb") as image:
        header = image.read(64)
        if header[:2] != b"MZ" or len(header) != 64:
            raise ValueError(f"missing PE header: {path}")
        image.seek(struct.unpack_from("<I", header, 60)[0])
        if image.read(6) != b"PE\0\0\x64\xaa":
            raise ValueError(f"not a native ARM64 PE binary: {path}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("destination", type=Path)
    parser.add_argument("--benchmark-source", default=ROOT / ".local/voxt-benchmark/Voxt", type=Path)
    parser.add_argument("--assets", default=ROOT / ".local/gguf-probe", type=Path)
    args = parser.parse_args()
    dest = args.destination.resolve()
    if dest.exists():
        raise FileExistsError(dest)
    lock = json.loads((ROOT / "sources.lock.json").read_text())
    revision = lock["llama_cpp"]["commit"]
    patch_id = file_hash(ROOT / "patches/llama-voxt.patch")[:12]
    vendor = ROOT / ".local/win-arm64"
    toolchain = vendor / "llvm-mingw-20261117"
    native = ROOT / "build" / f"windows-arm64-{patch_id}" / "bin"
    cache = native.parent / "CMakeCache.txt"
    if "GGML_OPENCL:BOOL=ON" not in cache.read_text():
        raise ValueError("the matching ARM64 build is missing OpenCL")
    dest.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=dest.parent) as directory:
        stage = Path(directory) / "stage"
        binary = stage / "bin"
        binary.mkdir(parents=True)
        shutil.copy2(native / "qwen3_asr_server.exe", binary)
        shutil.copy2(ROOT / "build/opencl-icd-arm64/OpenCL.dll", binary)
        for name in ("libc++.dll", "libunwind.dll", "libwinpthread-1.dll"):
            shutil.copy2(toolchain / "aarch64-w64-mingw32/bin" / name, binary)
        subprocess.run(
            ["go", "build", "-mod=readonly", "-o", str(binary / "final-benchmark.exe"), "./cmd/final-benchmark"],
            cwd=args.benchmark_source,
            env=os.environ | {"GOOS": "windows", "GOARCH": "arm64", "CGO_ENABLED": "0"},
            check=True,
        )
        for path in binary.iterdir():
            arm64_pe(path)
        imports = subprocess.check_output(
            [str(toolchain / "bin/llvm-objdump"), "-p", str(binary / "qwen3_asr_server.exe")], text=True,
        )
        if "DLL Name: OpenCL.dll" not in imports:
            raise ValueError("backend does not import the OpenCL loader")

        (stage / "models").mkdir()
        for installed, source in {
            "target.gguf": "Qwen3-ASR-1.7B-Q8_0.gguf",
            "mmproj.gguf": "mmproj-Qwen3-ASR-1.7B-f16.gguf",
            "draft-4.gguf": "draft-q4_0.gguf",
        }.items():
            archive = args.assets / source
            target = stage / "models" / installed
            try:
                os.link(archive, target)
            except OSError:
                shutil.copy2(archive, target)
        for key, sha in lock["benchmark"].items():
            remote = Path(key).name
            source = args.benchmark_source / "testdata/eval" / remote
            if file_hash(source) != sha:
                raise ValueError(f"benchmark hash mismatch: {remote}")
            (stage / "eval").mkdir(exist_ok=True)
            shutil.copy2(source, stage / "eval" / remote)
        (stage / "scripts/win-arm64").mkdir(parents=True)
        shutil.copy2(ROOT / "scripts/win-arm64/run_verify.ps1", stage / "scripts/win-arm64")
        shutil.copy2(ROOT / "Handoff.MD", stage)

        licenses = stage / "licenses"
        licenses.mkdir()
        license_sources = {
            "llama.cpp.txt": ROOT / f".local/llama-voxt-{revision[:8]}-{patch_id}/LICENSE",
            "Voxt.txt": args.benchmark_source / "LICENSE",
            "LLVM-MinGW.txt": toolchain / "LICENSE.TXT",
            "Khronos-OpenCL.txt": vendor / "OpenCL-ICD-Loader-b7bd2803acc779c03d96588e9ca9e9568a18698a/LICENSE",
        }
        for name, source in license_sources.items():
            shutil.copy2(source, licenses / name)
        shutil.copytree(toolchain / "aarch64-w64-mingw32/share/mingw32", licenses / "MinGW-w64",
                        ignore=shutil.ignore_patterns("*.xml", "*.h", "*.idl", "*.c"))
        files = {path.relative_to(stage).as_posix(): file_hash(path) for path in sorted(stage.rglob("*")) if path.is_file()}
        target_sha = lock["gguf_probe"]["files"]["Qwen3-ASR-1.7B-Q8_0.gguf"]
        if files["models/target.gguf"] != target_sha:
            raise ValueError("package Target hash does not match sources.lock.json")
        manifest = {
            "commit": subprocess.check_output(["git", "-C", str(ROOT), "rev-parse", "HEAD"], text=True).strip(),
            "llama_cpp": revision,
            "toolchain": "llvm-mingw 20261117 UCRT target aarch64-w64-mingw32",
            "build": "GGML_OPENCL=ON GGML_OPENCL_USE_ADRENO_KERNELS=ON GGML_CPU_ARM_ARCH=armv8.2-a+dotprod",
            "weights": "Q8_0 target, unquantized F16/F32 audio projector, Q4_0 draft (Q6_K output)",
            "files": files,
        }
        (stage / "verify_manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        stage.rename(dest)
    print(dest)


if __name__ == "__main__":
    main()

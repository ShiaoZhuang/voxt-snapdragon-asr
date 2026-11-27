#!/usr/bin/env python3
"""Build the pinned Voxt UI, SQLite library and Windows ARM64 microphone/hotkey helper."""

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


def arm64_pe(path):
    with path.open("rb") as src:
        if src.read(2) != b"MZ":
            return False
        src.seek(0x3C)
        src.seek(struct.unpack("<I", src.read(4))[0])
        return src.read(6) == b"PE\0\0\x64\xaa"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--voxt-repo", type=Path, help="existing sglang-omni checkout or bare repository")
    parser.add_argument("--output", type=Path, required=True, help="new output directory for the portable app")
    args = parser.parse_args()
    output = args.output.resolve()
    if output.exists():
        parser.error(f"output already exists: {output}")
    output.parent.mkdir(parents=True, exist_ok=True)
    lock = json.loads((ROOT / "sources.lock.json").read_text())["voxt"]
    with tempfile.TemporaryDirectory(dir=output.parent) as temp:
        work = Path(temp)
        repo = args.voxt_repo
        if repo is None:
            repo = work / "upstream.git"
            subprocess.run(["git", "init", "--bare", str(repo)], check=True)
            subprocess.run(["git", "-C", str(repo), "fetch", "--depth=1", "--filter=blob:none",
                            lock["repo"], lock["public_commit"]], check=True)
        archive = work / "voxt.tar"
        subprocess.run(["git", "-C", str(repo), "-c", "core.autocrlf=false", "archive",
                        f"--output={archive}", lock["public_commit"], "Voxt"], check=True)
        shutil.unpack_archive(archive, work)
        for name in ["voxt-mlx-baseline.patch", "voxt-windows-desktop.patch"]:
            patch = work / name
            patch.write_bytes((ROOT / "patches" / name).read_bytes().replace(b"\r\n", b"\n"))
            subprocess.run(["git", "-c", "core.autocrlf=false", "apply", "--no-index",
                            "--include=Voxt/*", str(patch)], cwd=work,
                           env={**os.environ, "GIT_CEILING_DIRECTORIES": str(work.parent)}, check=True)
        source = work / "Voxt"
        env = {**os.environ, "CGO_ENABLED": "0",
               "GOFLAGS": (os.environ.get("GOFLAGS", "") + " -buildvcs=false").strip()}
        subprocess.run(["go", "tool", "mygo", "build", "-platform", "windows/arm64",
                        "-o", str(work / "app"), "."], cwd=source, env=env, check=True)
        package = work / "app/windows-arm64"
        toolchain = subprocess.check_output(["go", "env", "GOVERSION"], cwd=source, env=env, text=True).strip()
        helper = package / "voxtnew-helper.exe"
        subprocess.run(["go", "build", "-trimpath", "-ldflags=-s -w", "-o", str(helper), "."],
                       cwd=ROOT / "native/windows-helper",
                       env={**env, "GOTOOLCHAIN": toolchain, "GOOS": "windows", "GOARCH": "arm64"}, check=True)
        manifest = source / "third_party/mygo/plugins/sqlite/mygo-plugin.json"
        sqlite = next(lib for lib in json.loads(manifest.read_text())["libraries"]
                      if lib["name"] == "mygo-sqlite3")["files"]["windows-arm64"]
        dll = package / sqlite["name"]
        if hashlib.sha256(dll.read_bytes()).hexdigest() != sqlite["sha256"]:
            raise RuntimeError(f"incorrect SHA-256 for {dll.name}")
        if not all(arm64_pe(path) for path in [package / "Voxt.exe", dll, helper]):
            raise RuntimeError("Voxt, its helper and SQLite must all be ARM64 PE files")
        package.rename(output)
    print(output)


if __name__ == "__main__":
    main()

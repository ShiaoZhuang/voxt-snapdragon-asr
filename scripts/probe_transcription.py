#!/usr/bin/env python3
"""Exercise an upstream llama.cpp build against one Voxt WAV."""

import argparse
import json
from pathlib import Path
import re
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--wav", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--cpu", action="store_true")
    parser.add_argument("--draft", type=Path)
    parser.add_argument(
        "--projector", type=Path,
        default=Path(".local/gguf-probe/mmproj-Qwen3-ASR-1.7B-bf16.gguf"),
    )
    args = parser.parse_args()
    args.output.mkdir()
    command = [
        "build/llama-probe/bin/llama-server", "--host", "127.0.0.1", "--port", "0",
        "-m", ".local/gguf-probe/Qwen3-ASR-1.7B-Q8_0.gguf",
        "--mmproj", str(args.projector),
        "--ctx-size", "8192", "--parallel", "1", "--jinja", "--temp", "0",
    ]
    if args.cpu:
        command += ["--device", "none", "--n-gpu-layers", "0", "--no-mmproj-offload"]
    if args.draft:
        command += [
            "--model-draft", str(args.draft), "--spec-type", "draft-dflash",
            "--spec-draft-n-max", "7", "--spec-draft-p-min", "0",
        ]
        if args.cpu:
            command += ["--spec-draft-device", "none", "--spec-draft-ngl", "0"]
    response = args.output / "response.sse"
    log = args.output / "server.log"
    (args.output / "command.json").write_text(json.dumps(command, indent=2) + "\n")
    with log.open("wb") as stderr:
        process = subprocess.Popen(command, stdout=stderr, stderr=stderr)
        try:
            deadline = time.monotonic() + 120
            while time.monotonic() < deadline:
                match = re.search(r"listening on (http://127\.0\.0\.1:\d+)", log.read_text())
                if match:
                    break
                if process.poll() is not None:
                    raise RuntimeError(f"server exited {process.returncode}; see {log}")
                time.sleep(0.1)
            else:
                raise TimeoutError(f"server did not listen; see {log}")
            with response.open("wb") as output:
                subprocess.run([
                    "curl", "--silent", "--show-error", "--fail-with-body", "--max-time", "120",
                    "--retry", "3", "--retry-connrefused",
                    "-F", f"file=@{args.wav};type=audio/wav",
                    "-F", "language=zh", "-F", "stream=true",
                    "-F", "temperature=0", "-F", "max_tokens=128",
                    match[1] + "/v1/audio/transcriptions",
                ], stdout=output, check=True)
            payloads = [line[5:].strip() for line in response.read_text().splitlines()
                        if line.startswith("data:")]
            events = [json.loads(payload) for payload in payloads if payload != "[DONE]"]
            completed = [event for event in events if event.get("type") == "transcript.text.done"]
            if payloads[-1:] != ["[DONE]"] or len(completed) != 1 or not completed[0].get("text"):
                raise RuntimeError(f"incomplete transcription; see {response}")
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()


if __name__ == "__main__":
    main()

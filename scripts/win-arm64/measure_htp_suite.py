"""Compare warm, verified HTP transcription on short and long Voxt clips."""
import argparse
from collections import Counter
from contextlib import contextmanager
import http.client
import io
import json
import os
from pathlib import Path
import queue
import re
import socket
import statistics
import subprocess
import threading
import time
import unicodedata
import wave

SEED = "zh-plain-1"
SAMPLES = (SEED, "en-3", "mix-1", "long-zh", "long-all")
TRIALS = 3


def load_samples(folder):
    manifest = json.loads((folder / "clips.json").read_text(encoding="utf-8"))
    clips = {c["id"]: c for c in manifest["clips"]}
    longs = {c["id"]: c for c in manifest["long"]}
    samples = {}
    for name in SAMPLES:
        meta = clips[name] if name in clips else longs[name]
        ids = meta.get("of", [name])
        parts = []
        for key in ids:
            with wave.open(str(folder / (key + ".wav")), "rb") as wav:
                if (wav.getnchannels(), wav.getsampwidth(), wav.getframerate()) != (1, 2, 16000):
                    raise ValueError(f"{key}: expected mono 16 kHz PCM16")
                parts.append(wav.readframes(wav.getnframes()))
        pcm = bytes(2 * int(meta.get("gap", 0) * 16000)).join(parts)
        data = io.BytesIO()
        with wave.open(data, "wb") as wav:
            wav.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
            wav.writeframes(pcm)
        samples[name] = (data.getvalue(), len(pcm) / 32000, meta["lang"],
                         " ".join(clips[key]["text"] for key in ids))
    return samples


def units(text):
    # Raw mixed error rate: one Han character or one Latin word/number per unit.
    text = unicodedata.normalize("NFKC", text).casefold().replace("’", "'")
    return re.findall(r"[\u3400-\u9fff]|[a-z0-9]+(?:'[a-z0-9]+)*", text)


def errors(reference, text):
    ref, hyp = units(reference), units(text)
    row = list(range(len(hyp) + 1))
    for i, a in enumerate(ref, 1):
        previous, row = row, [i]
        for j, b in enumerate(hyp, 1):
            row.append(min(previous[j] + 1, row[-1] + 1, previous[j-1] + (a != b)))
    return row[-1], len(ref)


@contextmanager
def server(args, draft, profile, ubatch, log, *, target_backend="hexagon", draft_backend="hexagon",
           extra_env=None, with_pid=False):
    command = [str(args.server), "--supervised", "--backend", target_backend, "--audio-backend", "hexagon",
               "--model-directory", str(args.assets / "models")]
    if draft:
        command += ["--draft-model-path", str(args.assets / "models"), "--draft-bits", "4", "--draft-backend", draft_backend]
    env = dict(os.environ, VOXT_ASR_TRACE="1", OMNI_DFLASH_PROFILE="1", GGML_HEXAGON_DEVICES="HTP0",
               GGML_HEXAGON_LIBHTP_DIR=str(args.ops), GGML_HEXAGON_PROFILE=str(int(profile)),
               GGML_HEXAGON_OPPOLL="0", GGML_HEXAGON_OPBATCH="2048", GGML_HEXAGON_OPFUSION="1",
               VOXT_AUDIO_POS_BROADCAST="0", VOXT_AUDIO_CONV_LAYOUT="0", GGML_HEXAGON_OPQUEUE="8",
               LLAMA_ARG_LOG_VERBOSITY="5", LLAMA_ARG_UBATCH=str(ubatch), LLAMA_ARG_BATCH="2048")
    for key in ("VOXT_QNN_VERIFY_DIR", "VOXT_QNN_VERIFY_PORT", "VOXT_QNN_VERIFY_TOKEN",
                "VOXT_VERIFY_CAPTURE_DIR", "VOXT_VERIFY_CAPTURE_ALL_LAYERS"):
        env.pop(key, None)
    if extra_env:
        env.update(extra_env)
    started = time.perf_counter()
    with log.open("wb") as stderr, subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                                     stderr=stderr, env=env) as child:
        ready = queue.Queue()
        threading.Thread(target=lambda: ready.put(child.stdout.readline()), daemon=True).start()
        try:
            try:
                msg = json.loads(ready.get(timeout=120))
            except queue.Empty as exc:
                raise TimeoutError(f"120 s waiting for ready; see {log.name}") from exc
            if msg.get("event") != "ready" or msg.get("host") != "127.0.0.1":
                raise RuntimeError(f"invalid ready response; see {log.name}")
            result = (msg["port"], (time.perf_counter() - started) * 1000)
            yield (*result, child.pid) if with_pid else result
        finally:
            child.stdin.close()
            try:
                child.wait(timeout=8)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()
        if child.returncode:
            raise RuntimeError(f"server exit {child.returncode}; see {log.name}")


def request(port, sample):
    wav, duration, lang, reference = sample
    boundary = b"voxt-htp-suite-boundary"
    parts = [b'Content-Disposition: form-data; name="file"; filename="input.wav"\r\nContent-Type: audio/wav\r\n\r\n' + wav]
    for key, value in (("language", lang), ("include_generation_metadata", "true"), ("stream", "true")):
        parts.append(f'Content-Disposition: form-data; name="{key}"\r\n\r\n{value}'.encode())
    body = b"".join(b"--" + boundary + b"\r\n" + part + b"\r\n" for part in parts) + b"--" + boundary + b"--\r\n"
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=180)
    deadline_hit = threading.Event()

    def abort(sock):
        deadline_hit.set()
        try:
            sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass

    start = time.perf_counter()
    conn.connect()
    deadline = threading.Timer(180, abort, (conn.sock,))
    deadline.start()
    try:
        conn.request("POST", "/v1/audio/transcriptions", body, {"Content-Type": "multipart/form-data; boundary=" + boundary.decode()})
        response = conn.getresponse()
        raw = response.read()
        ms = (time.perf_counter() - start) * 1000
    finally:
        deadline.cancel()
        conn.close()
        if deadline_hit.is_set():
            raise TimeoutError("transcription exceeded 180 s")
    data = [line[6:] for line in raw.decode().splitlines() if line.startswith("data: ")]
    if response.status != 200 or data[-1:] != ["[DONE]"]:
        raise RuntimeError(f"HTTP {response.status}, incomplete response: {raw[-350:]!r}")
    events = [json.loads(line) for line in data[:-1]]
    done = next((ev for ev in events if ev.get("type") == "transcript.text.done"), None)
    if not done or not done.get("text"):
        raise RuntimeError(f"no complete transcript: {raw[-350:]!r}")
    m = done["generation_metadata"]
    if m["finish_reason"] != "stop" or not m["token_ids"] or m["generated_token_count"] <= 0:
        raise RuntimeError(f"incomplete generation: {m['finish_reason']}")
    enc = m["audio_encoder_us"] / 1000
    if not 0 < enc <= ms or m["slot_prompt_ms"] + 1 < enc:
        raise ValueError(f"inconsistent encoder/prompt/request ms: {enc}/{m['slot_prompt_ms']}/{ms}")
    edits, count = errors(reference, done["text"])
    return dict(ms=ms, tps=m["generated_token_count"] * 1000 / ms, rtf=ms / (1000 * duration),
                input_ms=m["input_prepare_ms"], encoder_ms=enc, other_prompt_ms=m["slot_prompt_ms"] - enc,
                generation_ms=m["slot_generation_ms"], htp_events=m["audio_encoder_htp_events"],
                duration=duration, language=lang, reference=reference, text=done["text"], edits=edits, ref_units=count, meta=m)


def log_evidence(log):
    devices = []
    times = Counter()
    batches = []
    in_request = False
    with log.open(encoding="utf-8", errors="replace") as src:
        for line in src:
            device = re.search(r"llama_prepare_model_devices: using device (\S+) ", line)
            batch = re.search(r"n_ubatch\s+= (\d+)", line)
            if batch:
                batches.append(int(batch[1]))
            if device:
                devices.append(device[1])
            if "voxt: GGML Hexagon audio request started" in line:
                in_request = True
            if in_request and "profile-op" in line:
                op = re.search(r"HTP0 profile-op ([^| ]+).*?\|usec (\d+) cycles ([1-9]\d*)", line)
                if op and op[1] != "OPBATCH":
                    times[op[1]] += int(op[2])
    return devices, batches, times


def run_configuration(args, mode, profile, ubatch, samples, names, out, ref, mismatches):
    draft = mode == "dflash"
    config = f"{mode}-ub{ubatch}-profile{int(profile)}"
    log = args.logs / (config + ".stderr.log")
    print(f"[voxt] Starting {config}", flush=True)
    rows = {name: [] for name in names}
    with server(args, draft, profile, ubatch, log) as (port, startup):
        for rep in range(TRIALS + 1):
            order = [SEED] if rep == 0 else names[rep-1:] + names[:rep-1]
            for name in order:
                print(f"[voxt] {config} {name} {rep}/{TRIALS}", flush=True)
                r = request(port, samples[name])
                r.update(config=config, clip=name, rep=rep, startup_ms=startup)
                out.write(json.dumps(r, ensure_ascii=False) + "\n")
                out.flush()
                if profile and r["htp_events"] <= 0:
                    raise ValueError(f"{name}: no profiled HTP op in encoder")
                if draft and not r["meta"]["proposed_draft_token_count"]:
                    raise ValueError(f"{name}: draft did not propose any tokens")
                sequence = r["meta"]["token_ids"], r["text"]
                if sequence != ref.setdefault(name, sequence):
                    mismatches.add(f"{config}/{name}")
                if rep == 0:
                    cold = r["ms"]
                else:
                    rows[name].append(r)
    devices, batches, ops = log_evidence(log)
    if len(devices) < (2 if draft else 1) or set(devices) != {"HTP0"}:
        raise ValueError(f"unexpected Target/Draft devices: {devices}")
    if not batches or batches[0] != ubatch:
        raise ValueError(f"expected Target ubatch {ubatch}, logged {batches[:5]}")
    if profile and not sum(ops.values()):
        raise ValueError("no HTP operator timing after first request")
    medians = {name: sorted(group, key=lambda r: r["ms"])[TRIALS // 2] for name, group in rows.items()}
    return startup, cold, medians, ops


def measure(args):
    (args.logs / "htp-suite-summary.txt").write_text("", encoding="utf-8")
    samples = load_samples(args.assets / "eval")
    failures, ref, mismatches, results = [], {}, set(), {}

    def note(message):
        with (args.logs / "htp-suite-summary.txt").open("a", encoding="utf-8") as report:
            print(message, file=report)
        print(message, flush=True)

    # The same warm short request isolates the profiler. The long pair isolates ubatch.
    configs = [(mode, profile, 512, [SEED] if profile else list(samples))
               for mode in ("target", "dflash") for profile in (True, False)]
    configs.append(("dflash", False, 1024, ["long-zh", "long-all"]))
    with (args.logs / "htp-suite.jsonl").open("w", encoding="utf-8") as out:
        for mode, profile, ubatch, names in configs:
            try:
                startup, cold, med, ops = run_configuration(args, mode, profile, ubatch, samples, names, out, ref, mismatches)
                results[mode, profile, ubatch] = med
                if profile:
                    top = ", ".join(f"{op} {us / sum(ops.values()):.0%}" for op, us in ops.most_common(4))
                    note(f"{mode} short, share of profiled DSP op time: {top}")
                elif ubatch == 512:
                    note(f"{mode} short: ready {startup:.0f} ms | first request {cold:.0f} ms | warm {med[SEED]['ms']:.0f} ms")
                    for name in (SEED, "long-all"):
                        r = med[name]
                        phases = "/".join(f"{r[k]:.0f}" for k in ("input_ms", "encoder_ms", "other_prompt_ms", "generation_ms"))
                        note(f"{mode}/{name}: input/encoder/remaining prompt/generation ms {phases}")
                        if mode == "dflash":
                            m = r["meta"]
                            note(f"  draft/verify/context ms {m['draft_ms']:.0f}/{m['target_ms']:.0f}/{m['draft_context_ms']:.0f} | accepted {m['accepted_draft_token_count']}/{m['proposed_draft_token_count']}")
            except (OSError, ValueError, RuntimeError, KeyError, http.client.HTTPException) as exc:
                failures.append(f"{mode}-ub{ubatch}-profile{int(profile)}: {exc}")
                note("FAIL " + failures[-1])

    for mode in ("target", "dflash"):
        a, b = results.get((mode, True, 512)), results.get((mode, False, 512))
        if a and b:
            note(f"{mode} warm short profiling on/off ms: {a[SEED]['ms']:.0f}/{b[SEED]['ms']:.0f} ({a[SEED]['ms']/b[SEED]['ms']:.2f}x)")
    target, draft = (results.get((m, False, 512)) for m in ("target", "dflash"))
    if target and draft:
        note("Median warm request: Target / DFlash | tok/s | RTF | raw mixed error % (lower is better)")
        for name in samples:
            a, b = target[name], draft[name]
            note(f"{name} {a['duration']:.1f}s | {a['tps']:.2f}/{b['tps']:.2f} | {a['rtf']:.3f}/{b['rtf']:.3f} | {a['edits']/a['ref_units']:.1%}/{b['edits']/b['ref_units']:.1%}")
    wide = results.get(("dflash", False, 1024))
    if draft and wide:
        for name, b in wide.items():
            a = draft[name]
            note(f"{name} ubatch 512/1024 | {a['meta']['prompt_positions']} positions | remaining prompt {a['other_prompt_ms']:.0f}/{b['other_prompt_ms']:.0f} ms | request {a['ms']:.0f}/{b['ms']:.0f} ms ({a['ms']/b['ms']:.2f}x)")
    if mismatches:
        failures.append("token/text mismatch: " + ", ".join(sorted(mismatches)))
    if failures:
        raise RuntimeError("; ".join(failures))
    note("PASS | matched complete token sequences and transcripts for each clip.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for key in ("server", "assets", "ops", "logs"):
        parser.add_argument("--" + key, type=Path, required=True)
    options = parser.parse_args()
    try:
        measure(options)
    except Exception as exc:
        with (options.logs / "htp-suite-summary.txt").open("a", encoding="utf-8") as f:
            print(f"INCOMPLETE: {exc}", file=f)
        raise

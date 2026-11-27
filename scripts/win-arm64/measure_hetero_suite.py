"""Measure four Target/DFlash placements with HTP audio on short and long speech."""
import argparse
from collections import Counter
import http.client
import json
from pathlib import Path
import re

from measure_htp_suite import SEED, TRIALS, load_samples, log_evidence, request, server

CLIPS = (SEED, "long-zh")
DEVICES = {"opencl": "GPUOpenCL", "hexagon": "HTP0"}
PLACEMENTS = (("hexagon", "hexagon"), ("opencl", "hexagon"), ("opencl", "opencl"), ("hexagon", "opencl"))
UBATCH = 512


def verify_log(path, target, draft, profiled):
    devices, batches, ops = log_evidence(path)
    expected = [DEVICES[target]] + ([DEVICES[draft]] if draft else [])
    if devices != expected or not batches or batches[0] != UBATCH:
        raise ValueError(f"expected devices {expected} and Target ubatch {UBATCH}, got {devices}, {batches}")
    if profiled and not sum(ops.values()):
        raise ValueError("no timed HTP0 operator during the profiled short request")
    file_types, audio_devices, tensor_types = [], [], Counter()
    with path.open(encoding="utf-8", errors="replace") as log:
        for line in log:
            if "voxt: GGML Hexagon audio request started" in line:
                break
            if match := re.search(r"print_info:\s+file type\s*=\s*(\S+)", line):
                file_types.append(match[1])
            if match := re.search(r"mtmd_backends:\s+using (\S+) backend", line):
                audio_devices.append(match[1])
            if "mtmd_model_loader: tensor[" in line and (match := re.search(r"\btype = (\w+)", line)):
                tensor_types[match[1]] += 1
    expected_types = ["Q8_0"] + (["Q4_0"] if draft else [])
    if file_types != expected_types or audio_devices != ["HTP0"] or not tensor_types["f16"]:
        raise ValueError(f"loader evidence: model types {file_types}, audio backend {audio_devices}, "
                         f"audio tensor types {dict(tensor_types)}")
    return f"audio HTP0 {dict(tensor_types)}, models {'/'.join(devices)} {'/'.join(file_types)}"


def run(args, samples, out, target, draft, phase, reference):
    label = f"target-{target}_draft-{draft or 'none'}"
    log = args.logs / f"hetero-{label}-{phase}.stderr.log"
    profiled = phase == "profile"
    if phase == "warm":
        # Give each clip one warm-up then alternate lengths for the timed trials.
        trials = [(clip, rep) for rep in range(TRIALS + 1) for clip in CLIPS]
    else:
        trials = [(clip, 0) for clip in ((SEED,) if profiled else CLIPS)]
    measured = {clip: [] for clip in CLIPS}
    mismatches = set()
    observed = {}
    with server(args, bool(draft), profiled, UBATCH, log, target_backend=target,
                draft_backend=draft or "hexagon") as (port, startup):
        for clip, rep in trials:
            print(f"[voxt] {label} {phase} {clip} {rep}", flush=True)
            row = request(port, samples[clip])
            row.update(config=label, phase=phase, clip=clip, rep=rep, startup_ms=startup)
            out.write(json.dumps(row, ensure_ascii=False) + "\n")
            out.flush()
            meta = row["meta"]
            sequence = (meta["token_ids"], row["text"])
            if phase == "reference":
                observed[clip] = sequence
            elif clip in reference and sequence != reference[clip]:
                mismatches.add(clip)
            if draft and (meta["verify_round_count"] < 1 or meta["proposed_draft_token_count"] < 1):
                raise ValueError(f"{clip}: no DFlash proposals or verification rounds")
            if profiled and row["htp_events"] < 1:
                raise ValueError(f"{clip}: no HTP0 encoder events")
            if rep > 0 or profiled:
                measured[clip].append(row)
    evidence = verify_log(log, target, draft, profiled)
    reference.update(observed)
    if mismatches:
        raise ValueError(f"token IDs or transcript differ from HTP Target-only: {sorted(mismatches)}")
    return measured, evidence


def measure(args):
    args.logs.mkdir(parents=True, exist_ok=True)
    with (args.logs / "hetero-suite-summary.txt").open("w", encoding="utf-8") as summary, \
            (args.logs / "hetero-suite.jsonl").open("w", encoding="utf-8") as out:
        def note(line):
            print(line, file=summary, flush=True)
            print(line, flush=True)

        samples = load_samples(args.assets / "eval")
        reference, failures, medians = {}, [], {}
        runs = [("hexagon", None, "reference")]
        runs += [(t, d, phase) for t, d in PLACEMENTS for phase in ("profile", "warm")]
        for target, draft, phase in runs:
            name = f"{DEVICES[target]}/{DEVICES[draft] if draft else 'none'}"
            try:
                rows, evidence = run(args, samples, out, target, draft, phase, reference)
                if phase == "profile":
                    note(f"{name} short evidence | {evidence} | encoder HTP events {rows[SEED][0]['htp_events']}")
                elif phase == "warm":
                    for clip in CLIPS:
                        r = sorted(rows[clip], key=lambda row: row["ms"])[TRIALS // 2]
                        m = r["meta"]
                        medians[target, draft, clip] = r["ms"]
                        note(f"{name} {clip} {r['duration']:.1f}s | {r['ms']:.0f} ms {r['tps']:.2f} tok/s "
                             f"RTF {r['rtf']:.3f} | encoder/draft/verify {r['encoder_ms']:.1f}/"
                             f"{m['draft_ms']:.1f}/{m['target_ms']:.1f} ms | accepted/proposed "
                             f"{m['accepted_draft_token_count']}/{m['proposed_draft_token_count']} | "
                             f"raw mixed errors {r['edits']}/{r['ref_units']}")
                else:
                    note(f"Target-only transcript and token references | {evidence}")
            except (OSError, KeyError, ValueError, RuntimeError, http.client.HTTPException) as exc:
                failures.append(f"{name} {phase}: {exc}")
                note("FAIL " + failures[-1])
        for clip in CLIPS:
            baseline = medians.get(("hexagon", "hexagon", clip))
            if baseline:
                for target, draft in PLACEMENTS[1:]:
                    ms = medians.get((target, draft, clip))
                    if ms:
                        note(f"{clip} HTP/HTP median request ms divided by "
                             f"{DEVICES[target]}/{DEVICES[draft]}: {baseline/ms:.2f}x")
        if failures:
            note(f"INCOMPLETE | {len(failures)} failed configuration/phase(s)")
            raise RuntimeError("; ".join(failures))
        note(f"PASS | all clip token IDs and transcripts match HTP Target-only; "
             f"timings are median of {TRIALS} warm requests with DSP profiling off.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for key in ("server", "assets", "ops", "logs"):
        parser.add_argument("--" + key, type=Path, required=True)
    measure(parser.parse_args())

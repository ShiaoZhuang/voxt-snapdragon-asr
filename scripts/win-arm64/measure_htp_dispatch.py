"""Measure HTP operator batch size sensitivity on the signed v73 runtime."""
import argparse
from collections import Counter, defaultdict
import json
from pathlib import Path
import re
from statistics import median

from measure_htp_suite import SEED, TRIALS, load_samples, request, server


SMALL, DEFAULT = 8, 2048
CAP = re.compile(r"ggml-hex: HTP0 op batching: .*? n-ops (\d+) ")
DEVICE = re.compile(r"llama_prepare_model_devices: using device (\S+) ")
OP = re.compile(r"ggml-hex: HTP0 profile-op ([^|]+)\|.*?\|usec (\d+) cycles (\d+)")
BATCH = re.compile(r"\|n-ops (\d+)\|")


def read_log(path, cap, profile, n_requests):
    """Associate device responses with serial HTTP requests, excluding startup."""
    caps, devices, requests = [], [], []
    remaining = 0
    with path.open(encoding="utf-8", errors="replace") as stream:
        for line in stream:
            if match := CAP.search(line):
                caps.append(int(match[1]))
            if match := DEVICE.search(line):
                devices.append(match[1])
            if "voxt: GGML Hexagon audio request started" in line:
                if remaining:
                    raise ValueError(f"{path.name}: incomplete batch before request")
                requests.append(dict(batch_sizes=Counter(), ops=Counter(), batch_us=0, op_us=0))
            if not requests or "ggml-hex: HTP0 profile-op " not in line:
                continue
            row = requests[-1]
            match = OP.search(line)
            if not profile or not match:
                raise ValueError(f"{path.name}: unexpected operator record")
            name, usec = match[1], int(match[2])
            if name == "OPBATCH":
                size = BATCH.search(line)
                if remaining or not size or not 0 < int(size[1]) <= cap or not int(match[3]):
                    raise ValueError(f"{path.name}: invalid batch record")
                remaining = int(size[1])
                row["batch_sizes"][remaining] += 1
                row["batch_us"] += usec
            else:
                if not remaining:
                    raise ValueError(f"{path.name}: extra operator record")
                remaining -= 1
                row["ops"][name] += 1
                row["op_us"] += usec
    if len(devices) < 2 or set(devices) != {"HTP0"} or set(caps) != {cap}:
        raise ValueError(f"{path.name}: expected Target/Draft HTP0, cap {cap}, saw {devices}, {caps}")
    if len(requests) != n_requests or remaining or (profile and any(not r["ops"] for r in requests)):
        raise ValueError(f"{path.name}: missing request or DSP records")
    return requests


def measure(args, report):
    sample = load_samples(args.assets / "eval")[SEED]
    reference = None
    timed = defaultdict(list)
    traced = {}
    # Reverse the order of the second pair to reduce drift from warming clocks.
    plan = [(DEFAULT, False), (SMALL, False), (SMALL, False), (DEFAULT, False),
            (DEFAULT, True), (SMALL, True)]
    with (args.logs / "htp-dispatch.jsonl").open("w", encoding="utf-8") as raw:
        for index, (cap, profile) in enumerate(plan):
            log = args.logs / f"dispatch-{index + 1}-cap{cap}-profile{int(profile)}.stderr.log"
            print(f"[voxt] Measuring {log.stem}", flush=True)
            env = {"GGML_HEXAGON_OPFUSION": "0", "GGML_HEXAGON_OPBATCH": str(cap)}
            rows = []
            with server(args, True, profile, 512, log, extra_env=env) as (port, _):
                for rep in range(1 + (1 if profile else TRIALS)):
                    row = request(port, sample)
                    seq = (row["meta"]["token_ids"], row["text"])
                    if reference is None:
                        reference = seq
                    if seq != reference or not row["meta"]["proposed_draft_token_count"]:
                        raise ValueError(f"{log.stem}/{rep}: different tokens/text or inactive draft")
                    if profile and row["htp_events"] <= 0:
                        raise ValueError(f"{log.stem}/{rep}: no HTP events during encoding")
                    rows.append(row)
            for rep, (row, trace) in enumerate(zip(rows, read_log(log, cap, profile, len(rows)))):
                raw.write(json.dumps(dict(run=index + 1, clip=SEED, cap=cap, profile=profile,
                                          warmup=rep == 0, response=row, trace=trace),
                                     ensure_ascii=False) + "\n")
                if rep and profile:
                    traced[cap] = trace
                elif rep:
                    timed[cap].append(row)
            raw.flush()

    if traced[SMALL]["ops"] != traced[DEFAULT]["ops"]:
        raise ValueError("different warm DSP operator histograms across caps; see htp-dispatch.jsonl")
    for cap in (SMALL, DEFAULT):
        rows, trace = timed[cap], traced[cap]
        n_batches = sum(trace["batch_sizes"].values())
        n_ops = sum(trace["ops"].values())
        residual = (trace["batch_us"] - trace["op_us"]) / 1000
        report(f"cap={cap} | warm median (n={len(rows)}, profile off) "
               f"request {median(r['ms'] for r in rows):.1f} ms, "
               f"encoder {median(r['encoder_ms'] for r in rows):.1f} ms, "
               f"generation {median(r['generation_ms'] for r in rows):.1f} ms")
        report(f"  Profiled warm request: {n_batches} batches, {n_ops} DSP ops, "
               f"{n_ops/n_batches:.1f} ops/batch, max {max(trace['batch_sizes'])}; "
               f"DSP batch total {trace['batch_us']/1000:.1f} ms, "
               f"operator total {trace['op_us']/1000:.1f} ms, difference {residual:.1f} ms")
    delta = median(r["ms"] for r in timed[SMALL]) - median(r["ms"] for r in timed[DEFAULT])
    report(f"Warm request median for cap {SMALL} minus {DEFAULT}: {delta:+.1f} ms.")
    if traced[SMALL]["batch_sizes"] == traced[DEFAULT]["batch_sizes"]:
        report("Both caps produced the same batch-size distribution on this clip.")
    report("DSP batch minus operator time includes setup, cache maintenance and synchronization. "
           "Host dispatch latency is not separately measured.")
    report("PASS | complete tokens/text and profiled operator counts agree across caps; OPFUSION=0.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for key in ("server", "assets", "ops", "logs"):
        parser.add_argument("--" + key, type=Path, required=True)
    args = parser.parse_args()
    args.logs.mkdir(parents=True, exist_ok=True)
    with (args.logs / "htp-dispatch-summary.txt").open("w", encoding="utf-8") as summary:
        def report(message):
            print(message, flush=True)
            print(message, file=summary, flush=True)

        try:
            measure(args, report)
        except Exception as exc:
            report(f"INCOMPLETE | {exc}")
            raise

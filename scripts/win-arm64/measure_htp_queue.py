"""Measure the host's outstanding HTP batch limit on a single transcription."""
import argparse
from collections import deque
from contextlib import closing, nullcontext
import json
from pathlib import Path
import re
from statistics import median

from measure_hetero_suite import verify_log
from measure_htp_suite import SEED, load_samples, request, server
from measure_htp_wait import ProcessCpu


DEFAULT_DEPTH = 8
CAP = 2048
START = "voxt: GGML Hexagon audio request started"
STOP = re.compile(r"slot\s+release:.*\bstop processing: n_tokens =")
ALLOC = re.compile(r"ggml-hex: HTP0 allocated opqueue : batch-size (\d+) depth (\d+) shm-size (\d+) slot-size (\d+)")
EVENT = re.compile(r"ggml-hex: HTP0 opqueue-(push|pop) batch #(\d+) : .*?n-ops (\d+) ")
BATCH = re.compile(r"ggml-hex: HTP0 op batching: .*?n-ops (\d+) vmem (\d+)")


def batch_vmem(log):
    # The backend subtracts the pinned queue/fence allocation from the v73 VA
    # budget before printing this value. It is logged even with profiling off.
    with log.open(encoding="utf-8", errors="replace") as stream:
        for line in stream:
            if match := BATCH.search(line):
                if int(match[1]) == CAP and int(match[2]) > 0:
                    return int(match[2])
                break
            if START in line:
                break
    raise ValueError(f"{log.name}: missing or incorrect batch cap / virtual-memory budget")


def read_queue_trace(log, depth):
    """Track the shared HTP0 session FIFO across startup, requests and teardown."""
    pending = deque()
    last_seq = 0
    queue_bytes = None
    requests = []
    active = None
    with log.open(encoding="utf-8", errors="replace") as stream:
        for line in stream:
            if match := ALLOC.search(line):
                cap, slots, size, slot_bytes = map(int, match.groups())
                if (queue_bytes is not None or (cap, slots) != (CAP, depth)
                        or slot_bytes <= 0 or size != depth * slot_bytes):
                    raise ValueError(f"{log.name}: unexpected HTP0 queue allocation {match.groups()}")
                queue_bytes = size
            elif START in line:
                if active is not None:
                    raise ValueError(f"{log.name}: missing slot release before next request")
                active = dict(peak=len(pending), batches=0, ops=0, at_limit=0)
            elif active is not None and STOP.search(line):
                if not active["batches"]:
                    raise ValueError(f"{log.name}: no HTP batch submitted in request")
                requests.append(active)
                active = None
            elif match := EVENT.search(line):
                kind, seq, ops = match[1], int(match[2]), int(match[3])
                if kind == "push":
                    if seq != last_seq + 1 or not 0 < ops <= CAP or len(pending) >= depth:
                        raise ValueError(f"{log.name}: invalid HTP0 queue submission #{seq}")
                    last_seq = seq
                    pending.append((seq, ops))
                    if active is not None:
                        active["peak"] = max(active["peak"], len(pending))
                        active["at_limit"] += int(len(pending) == depth)
                        active["batches"] += 1
                        active["ops"] += ops
                elif not pending or pending.popleft() != (seq, ops):
                    raise ValueError(f"{log.name}: unmatched HTP0 queue response #{seq}")
    if not queue_bytes or active is not None or pending or len(requests) != 2:
        raise ValueError(f"{log.name}: incomplete queue allocation, responses or request boundaries")
    return dict(queue_bytes=queue_bytes, warm=requests[1])


def output_signature(row, proof):
    meta = row["meta"]
    ids, count = meta["token_ids"], meta["generated_token_count"]
    if (meta["finish_reason"] != "stop" or not 0 < count <= len(ids) <= count + 1
            or any(type(token) is not int for token in ids) or meta["prompt_positions"] <= 0
            or meta["proposed_draft_token_count"] <= 0 or meta["verify_round_count"] <= 0
            or not 0 <= meta["accepted_draft_token_count"] <= meta["proposed_draft_token_count"]
            or meta["live_verify_round_count"] != 0 or (row["htp_events"] > 0) != proof
            or "draft_ms" in meta):
        raise ValueError("unexpected DFlash, token, prompt or profiler metadata")
    return (ids, row["text"], count, meta["prompt_positions"], meta["accepted_draft_token_count"],
            meta["proposed_draft_token_count"], meta["verify_round_count"])


def measure(args, note):
    sample = load_samples(args.assets / "eval")[SEED]
    reference = None
    verified_vmem = {}
    note(f"Queue | {SEED} | HTP0 Q8 Target/Q4 DFlash | ubatch 512, cap {CAP}, fusion on, blocking")
    with (args.logs / "htp-queue.jsonl").open("w", encoding="utf-8") as raw:
        def run(depth, launch, proof=False):
            nonlocal reference
            log = args.logs / f"queue-{launch}-depth{depth}.stderr.log"
            env = {"GGML_HEXAGON_OPQUEUE": str(depth), "GGML_HEXAGON_VERBOSE": str(int(proof)),
                   "GGML_HEXAGON_VMEM": "3000M", "VOXT_AUDIO_CONV_LAYOUT": "0", "OMNI_DFLASH_PROFILE": "0"}
            print(f"[voxt] Starting {launch} with queue depth {depth}", flush=True)
            warm = []
            with server(args, True, proof, 512, log, extra_env=env, with_pid=True) as (port, startup, pid):
                with (nullcontext(None) if proof else closing(ProcessCpu(pid))) as cpu:
                    for rep in range(2 if proof else 3):
                        before = cpu.milliseconds() if cpu else None
                        row = request(port, sample)
                        if cpu:
                            row["cpu_ms"] = cpu.milliseconds() - before
                        row.update(launch=launch, depth=depth, rep=rep, proof=proof, clip=SEED, startup_ms=startup)
                        raw.write(json.dumps(row, ensure_ascii=False) + "\n")
                        raw.flush()
                        signature = output_signature(row, proof)
                        if reference is None:
                            reference = signature
                        elif signature != reference:
                            raise ValueError(f"{log.name}/{rep}: tokens, text, prompt or draft workload changed")
                        if rep:
                            warm.append(row)
            verify_log(log, "hexagon", "hexagon", proof)
            vmem = batch_vmem(log)
            if proof:
                trace = read_queue_trace(log, depth)
                verified_vmem[depth] = vmem
                capture = trace["warm"]
                note(f"Queue trace depth {depth} | peak {capture['peak']} outstanding, "
                     f"{capture['at_limit']} submissions reached limit | {capture['batches']} batches, "
                     f"{capture['ops']} ops | queue storage {trace['queue_bytes']} bytes")
                return trace
            if vmem != verified_vmem[depth]:
                raise ValueError(f"{log.name}: timing run batch memory budget differs from queue proof")
            return warm

        baseline = run(DEFAULT_DEPTH, "proof-base", True)
        peak = baseline["warm"]["peak"]
        candidate = 2 * DEFAULT_DEPTH if peak == DEFAULT_DEPTH else peak
        note(f"Queue candidate depth {candidate} | "
             + ("test more outstanding batches after reaching depth 8" if peak == DEFAULT_DEPTH else
                "reduce shared memory to the measured warm peak"))
        changed = run(candidate, "proof-candidate", True)
        delta_bytes = changed["queue_bytes"] - baseline["queue_bytes"]
        if changed["queue_bytes"] * DEFAULT_DEPTH != baseline["queue_bytes"] * candidate:
            raise ValueError("queue slot size changed across arms")
        if (verified_vmem[candidate] - verified_vmem[DEFAULT_DEPTH]) * delta_bytes >= 0:
            raise ValueError("HTP batch memory budget did not reflect the change in pinned queue size")
        note(f"Queue storage change {delta_bytes:+d} bytes. Outstanding counts host submissions "
             "awaiting host collection; DSP completion may precede collection.")
        runs = [run(depth, i) for i, depth in enumerate((DEFAULT_DEPTH, candidate, candidate, DEFAULT_DEPTH), 1)]

    phases = ("ms", "encoder_ms", "generation_ms", "cpu_ms")
    for depth, rows in ((DEFAULT_DEPTH, runs[0] + runs[3]), (candidate, runs[1] + runs[2])):
        times = "/".join(f"{median(row[k] for row in rows):.1f}" for k in phases)
        note(f"Queue depth {depth} | median request/encoder/generation/server CPU {times} ms, "
             f"{len(rows)} warm requests in two processes")
    for a, b in ((0, 1), (3, 2)):
        delta = median(row["ms"] for row in runs[b]) - median(row["ms"] for row in runs[a])
        note(f"Queue pair {a+1}/{b+1} | candidate minus baseline warm median request {delta:+.1f} ms")
    if candidate > DEFAULT_DEPTH and changed["warm"]["peak"] <= DEFAULT_DEPTH:
        note("Queue trace | deeper queue allocated; the warm candidate used at most eight slots.")
    note("PASS | complete tokens, text and draft workload agree. ABBA timing excludes both diagnostic runs.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for key in ("server", "assets", "ops", "logs"):
        parser.add_argument("--" + key, type=Path, required=True)
    args = parser.parse_args()
    args.logs.mkdir(parents=True, exist_ok=True)
    with (args.logs / "htp-queue-summary.txt").open("w", encoding="utf-8") as summary:
        def note(message):
            print(message, flush=True)
            print(message, file=summary, flush=True)

        try:
            measure(args, note)
        except Exception as exc:
            note(f"INCOMPLETE | {exc}")
            raise

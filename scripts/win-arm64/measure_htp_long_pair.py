"""Compare all-HTP Target and DFlash on long-all in ABBA launch order."""
import argparse
import json
from pathlib import Path

from measure_hetero_suite import verify_log
from measure_htp_suite import load_samples, request, server

CLIP = "long-all"
ORDER = ("target", "dflash", "dflash", "target")
PHASES = ("ms", "input_ms", "encoder_ms", "other_prompt_ms", "generation_ms")


def measure(args, report):
    sample = load_samples(args.assets / "eval")[CLIP]
    reference = None
    measured = []

    def note(line):
        print(line, file=report, flush=True)
        print(line, flush=True)

    note(f"{CLIP} {sample[1]:.1f}s | all HTP, ubatch 512 | Target/DFlash/DFlash/Target | "
         "fresh server per arm; same clip for warm-up and second request")
    note("Phase values in ms: request / input / encoder / remaining prompt / generation.")
    with (args.logs / "htp-long-pair.jsonl").open("w", encoding="utf-8") as out:
        for launch, mode in enumerate((*ORDER, "dflash"), 1):
            evidence_only = launch > len(ORDER)
            log = args.logs / f"htp-long-pair-{launch}-{mode}.stderr.log"
            draft = mode == "dflash"
            stages = ("evidence",) if evidence_only else ("warm-up", "steady")
            print(f"[voxt] Starting {launch} {mode} ({', '.join(stages)})", flush=True)
            with server(args, draft, evidence_only, 512, log,
                        extra_env={"OMNI_DFLASH_PROFILE": "0"}) as (port, startup):
                for stage in stages:
                    row = request(port, sample)
                    row.update(launch=launch, mode=mode, clip=CLIP, stage=stage,
                               dsp_profile=evidence_only, startup_ms=startup)
                    out.write(json.dumps(row, ensure_ascii=False) + "\n")
                    out.flush()
                    m = row["meta"]
                    count, ids = m["generated_token_count"], m["token_ids"]
                    proposed, accepted = m["proposed_draft_token_count"], m["accepted_draft_token_count"]
                    rounds = m["verify_round_count"]
                    if (not 0 <= accepted <= proposed or (proposed > 0) != draft or
                            (rounds > 0) != draft or m["live_verify_round_count"] != 0):
                        raise ValueError(f"unexpected {mode} trace in launch {launch}: "
                                         f"{accepted}/{proposed} accepted, {rounds} rounds")
                    if not count <= len(ids) <= count + 1 or m["prompt_positions"] <= 0:
                        raise ValueError(f"incomplete token or prompt trace in launch {launch}")
                    sequence = (ids, row["text"], count, m["prompt_positions"])
                    if reference is None:
                        reference = sequence
                    elif sequence != reference:
                        raise ValueError(f"launch {launch} {stage}: output or prompt differs from first Target")
                    if evidence_only:
                        if row["htp_events"] <= 0:
                            raise ValueError("no HTP operator recorded inside the long-all encoder")
                        note(f"Independent long-all DFlash trace | {row['htp_events']} HTP encoder events")
                    else:
                        if row["htp_events"] != 0 or "draft_ms" in m:
                            raise ValueError(f"launch {launch} {stage}: profiling enabled during timing")
                        times = "/".join(f"{row[key]:.1f}" for key in PHASES)
                        note(f"{launch} {mode} {stage} | {times} ms | {row['tps']:.2f} tok/s "
                             f"RTF {row['rtf']:.3f} | raw errors {row['edits']}/{row['ref_units']} "
                             f"| accepted/proposed {accepted}/{proposed}")
                        measured.append(row)
            evidence = verify_log(log, "hexagon", "hexagon" if draft else None, evidence_only)
            note(f"Launch {launch} | {evidence} | ready {startup:.0f} ms")

    note("Signed paired differences (DFlash minus Target), in the same phase order:")
    for first, second in ((1, 2), (4, 3)):
        for stage in ("warm-up", "steady"):
            target, draft = (next(row for row in measured if row["launch"] == launch and row["stage"] == stage)
                             for launch in (first, second))
            delta = "/".join(f"{draft[key] - target[key]:+.1f}" for key in PHASES)
            note(f"Launches Target {first}, DFlash {second} {stage} | {delta} ms")
    note("PASS | identical complete token IDs, text and prompt length across all nine requests. "
         "Two steady requests per mode; paired differences are descriptive.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for key in ("server", "assets", "ops", "logs"):
        parser.add_argument("--" + key, type=Path, required=True)
    options = parser.parse_args()
    options.logs.mkdir(parents=True, exist_ok=True)
    with (options.logs / "htp-long-pair-summary.txt").open("w", encoding="utf-8") as report:
        try:
            measure(options, report)
        except Exception as exc:
            print(f"INCOMPLETE | {exc}", file=report)
            raise

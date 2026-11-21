#!/usr/bin/env python3
"""Aggregate Voxt Final-only JSONL outputs without rounding individual clips."""

import argparse
from collections import Counter
import json
from pathlib import Path


CLEAN = {"zh-plain-1", "en-3", "en-4"}
TIMING = ("draft_ms", "target_ms", "draft_context_ms")


def summarize(rows):
    reference = sum(r["score"]["N"] for r in rows)
    edits = sum(r["score"][k] for r in rows for k in ("Sub", "Del", "Ins"))
    totals = Counter()
    for row in rows:
        for event in row["final_events"]:
            for name, value in event["generation_metadata"].items():
                if isinstance(value, (int, float)):
                    totals[name] += value
    rounds = totals["verify_round_count"]
    accepted = totals["accepted_draft_token_count"]
    proposed = totals["proposed_draft_token_count"]
    total_ms = sum(totals[key] for key in TIMING)
    return {
        "clips": len(rows),
        "reference_units": reference,
        "edits": edits,
        "error_rate": edits / reference,
        "rounds": rounds,
        "accepted": accepted,
        "proposed": proposed,
        "avg_accept": accepted / rounds if rounds else None,
        "avg_step": 1 + accepted / rounds if rounds else None,
        "accept_rate": accepted / proposed if proposed else None,
        "timing_fraction": {key: totals[key] / total_ms for key in TIMING} if total_ms else {},
        "ms_per_round": {key: totals[key] / rounds for key in TIMING} if total_ms else {},
        "elapsed_ms": sum(r["elapsed_ms"] for r in rows),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    args = parser.parse_args()
    summaries = {}
    transcripts = {}
    for mode in ("target-only", "draft-q4", "draft-q8"):
        path = args.directory / f"{mode}.jsonl"
        rows = [json.loads(line) for line in path.read_text().splitlines()]
        main_rows = [r for r in rows if r["variant"] == "main zh"]
        transcripts[mode] = {r["clip"]: r["text"] for r in main_rows}
        if len(transcripts[mode]) != 31 or len(main_rows) != 31:
            raise ValueError(f"{path}: expected 31 distinct main zh clips")
        if transcripts[mode].keys() != transcripts["target-only"].keys():
            raise ValueError(f"{path}: clip IDs differ from Target-only")
        groups = sorted({r["set"] for r in main_rows})
        summaries[mode] = {
            "all": summarize(main_rows),
            "clean": summarize([r for r in main_rows if r["clip"] in CLEAN]),
            "by_set": {g: summarize([r for r in main_rows if r["set"] == g]) for g in groups},
            "dictionary": {
                variant: {
                    "matched": sum(len(r.get("terms_found", [])) for r in rows
                                   if r["set"] == "dict" and r["variant"] == variant),
                    "expected": sum(len(r.get("terms", [])) for r in rows
                                    if r["set"] == "dict" and r["variant"] == variant),
                }
                for variant in ("main zh", "no bias")
            },
            "text_mismatches": [clip for clip, text in transcripts[mode].items()
                                if transcripts["target-only"][clip] != text],
        }
    print(json.dumps(summaries, indent=2))


if __name__ == "__main__":
    main()

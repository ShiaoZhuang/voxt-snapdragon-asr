"""Summarize long-clip warm requests from an existing htp-suite.jsonl."""
import argparse
import json
import math
from pathlib import Path
from statistics import median


CLIPS = ("long-zh", "long-all")
CONFIGS = {"target-ub512-profile0": "target", "dflash-ub512-profile0": "dflash"}


def read_groups(path):
    groups = {(clip, mode): {} for clip in CLIPS for mode in CONFIGS.values()}
    outputs = {}
    with path.open(encoding="utf-8-sig") as src:
        for number, line in enumerate(src, 1):
            try:
                r = json.loads(line)
                clip, config = r["clip"], r["config"]
                if clip not in CLIPS or config not in CONFIGS:
                    continue
                mode, rep, meta = CONFIGS[config], r["rep"], r["meta"]
                group = groups[clip, mode]
                if type(rep) is not int or rep not in (1, 2, 3) or rep in group:
                    raise ValueError(f"invalid or duplicate repeat {rep} for {config}/{clip}")
                for key in ("ms", "encoder_ms", "generation_ms"):
                    value = r[key]
                    if type(value) not in (int, float) or not math.isfinite(value) or value < 0:
                        raise ValueError(f"invalid {key}")
                if not 0 < r["encoder_ms"] <= r["ms"]:
                    raise ValueError("invalid encoder/request timing")
                seq = (meta["token_ids"], r["text"])
                if (meta["finish_reason"] != "stop" or not isinstance(seq[0], list) or not seq[0]
                        or any(type(token) is not int for token in seq[0])
                        or not isinstance(seq[1], str) or not seq[1] or seq != outputs.setdefault(clip, seq)):
                    raise ValueError(f"incomplete or different output for {clip}")
                if mode == "dflash":
                    a, p = meta["accepted_draft_token_count"], meta["proposed_draft_token_count"]
                    if type(a) is not int or type(p) is not int or not (p > 0 and 0 <= a <= p):
                        raise ValueError("invalid draft counts")
                group[rep] = r
            except (KeyError, TypeError, ValueError, OverflowError) as exc:
                raise ValueError(f"{path}, line {number}: {exc}") from exc

    for (clip, mode), rows in groups.items():
        if len(rows) != 3:
            raise ValueError(f"{path}, {clip}/{mode}: need repeats 1,2,3, found {sorted(rows)}")
    return groups


def summarize(path):
    groups = read_groups(path)
    lines = ["Warm ubatch=512, profiling off. Independent medians [min,max] in ms, n=3 per mode.",
             "Order: target / dflash. Deltas subtract unpaired medians (dflash - target)."]
    for clip in CLIPS:
        summaries = []
        for mode in ("target", "dflash"):
            rows = groups[clip, mode]
            summaries.append({k: sorted(row[k] for row in rows.values())
                              for k in ("ms", "encoder_ms", "generation_ms")})
        t, d = summaries

        def ranges(key):
            return " / ".join(f"{m[key][1]:.1f} [{m[key][0]:.1f},{m[key][2]:.1f}]"
                              for m in summaries)

        draft = groups[clip, "dflash"].values()
        a = sum(r["meta"]["accepted_draft_token_count"] for r in draft)
        p = sum(r["meta"]["proposed_draft_token_count"] for r in draft)
        gt, gd = median(t["generation_ms"]), median(d["generation_ms"])
        lines.append(f"{clip}: encoder {ranges('encoder_ms')} | wall {ranges('ms')}")
        lines.append(f"  generation {gt:.1f} / {gd:.1f} (delta {gd-gt:+.1f} ms)"
                     f" | draft accepted/proposed across 3 requests {a}/{p} ({a/p:.1%})")
    return lines


def compare(path, new_path):
    archives = (read_groups(path), read_groups(new_path))
    lines = ["Old -> new, independent medians of 3 warm requests per mode (ms). "
             "Ratios are old/new elapsed time; above 1x is faster. ubatch=512, profiling off."]
    for clip in CLIPS:
        # Historical JSONL includes the clip metadata and outputs, but no WAV digest.
        identity = None
        for archive in archives:
            for mode in CONFIGS.values():
                for row in archive[clip, mode].values():
                    duration, lang, reference = (row.get(key) for key in ("duration", "language", "reference"))
                    if (type(duration) not in (int, float) or not math.isfinite(duration) or duration <= 0
                            or not isinstance(lang, str) or not lang or not isinstance(reference, str) or not reference):
                        raise ValueError(f"{clip}: missing or invalid recorded clip metadata")
                    current = (duration, lang, reference, row["meta"]["token_ids"], row["text"])
                    if identity is None:
                        identity = current
                    elif current != identity:
                        raise ValueError(f"{clip}: different clip metadata or generated tokens/text across archives")
        for mode in CONFIGS.values():
            parts = []
            for key, label in (("ms", "wall"), ("encoder_ms", "encoder"), ("generation_ms", "generation")):
                old, new = (median(r[key] for r in g[clip, mode].values()) for g in archives)
                ratio = f"{old/new:.2f}x" if new else "n/a"
                parts.append(f"{label} {old:.1f}->{new:.1f} ({ratio})")
            lines.append(f"{clip}/{mode}: " + " | ".join(parts))
    return lines


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--path", type=Path, required=True)
    parser.add_argument("--compare", type=Path, help="newer htp-suite.jsonl for comparison")
    args = parser.parse_args()
    try:
        print("\n".join(compare(args.path, args.compare) if args.compare else summarize(args.path)))
    except (OSError, ValueError) as exc:
        parser.exit(1, f"INCOMPLETE: {exc}\n")

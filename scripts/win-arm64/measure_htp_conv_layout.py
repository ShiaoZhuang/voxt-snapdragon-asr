"""Measure Qwen3-ASR convolution layout on the signed v73 HTP runtime."""
import argparse
from collections import Counter
import hashlib
import json
from math import prod
from pathlib import Path
import re
from statistics import median

import measure_htp_suite as suite
from measure_htp_fusion import PROFILE_OP, REQUEST_START, write_row


CLIPS = (suite.SEED, "long-zh")
ARMS = ("packed", "view")
LAYERS = {1, 2, 3}
COL_WEIGHT = re.compile(r"\ba\.conv2d\.([123])\.weight\b")
PRODUCERS = {"pack": {"CONT", "CPY"}, "cols": {"IM2COL"}, "layout_act": {"GELU_ERF"}}
TAG = re.compile(r"voxt_conv_(pack|cols|layout_act)-([123])")


def read_profiles(path):
    groups = []
    with path.open(encoding="utf-8", errors="replace") as src:
        for line in src:
            if REQUEST_START in line:
                groups.append([])
                continue
            if not groups or "HTP0 profile-op" not in line:
                continue
            match = PROFILE_OP.search(line)
            if not match or not int(match[5]):
                continue
            op, tensors, dims, usec, _ = match.groups()
            outputs = tensors.rpartition(" -> ")[2].split(" x ")
            shapes = dims.rpartition(" -> ")[2].split(" x ")
            tags = [(m[1], int(m[2]), shape) for t, shape in zip(outputs, shapes) if (m := TAG.fullmatch(t))]
            weight = COL_WEIGHT.search(tensors.partition(" -> ")[0]) if op == "IM2COL" else None
            if tags or weight:
                groups[-1].append(dict(op=op, tensors=tensors, dims=dims, dsp_us=int(usec),
                                       im2col_layer=int(weight[1]) if weight else None, tags=tags))
    return groups


def check_path(records, arm):
    counts = {kind: [] for kind in ("pack", "cols", "layout_act")}
    layouts = Counter()
    im2col_counts = Counter(row["im2col_layer"] for row in records if row["im2col_layer"])
    for row in records:
        for kind, layer, shape in row["tags"]:
            counts[kind].append(layer)
            operations = set(row["op"].split("+"))
            if not PRODUCERS[kind].intersection(operations) or (kind == "cols" and layer != row["im2col_layer"]):
                raise ValueError(f"unexpected HTP producer for layer {layer}: {row}")
            if kind != "cols":
                w, h, z, t = map(int, shape.split(":"))
                channels, chunks = (z, t) if kind == "pack" else (t, z)
                layouts[layer, w, h, channels, chunks] += 1
    expected = {"pack"} if arm == "packed" else {"cols", "layout_act"}
    if {k for k, v in counts.items() if v} != expected:
        raise ValueError(f"{arm}: unexpected or missing HTP path, layer tags {counts}")
    for kind in expected:
        hits = counts[kind]
        if set(hits) != LAYERS or Counter(hits) != im2col_counts or len(set(im2col_counts.values())) != 1:
            raise ValueError(f"{arm}: incomplete HTP convolution evidence, {counts}, IM2COL={im2col_counts}")
    return sum(im2col_counts.values()), layouts


def measure(args):
    args.logs.mkdir(parents=True, exist_ok=True)
    summary = args.logs / "htp-conv-layout-summary.txt"
    sequences, warm, baseline_layouts = {}, {}, {}
    with summary.open("w", encoding="utf-8") as report, \
         (args.logs / "htp-conv-layout.jsonl").open("w", encoding="utf-8") as rows, \
         (args.logs / "htp-conv-layout-profile.jsonl").open("w", encoding="utf-8") as profiles:
        def note(line):
            print(line, flush=True)
            print(line, file=report, flush=True)

        samples = suite.load_samples(args.assets / "eval")
        release = json.loads((Path(__file__).resolve().parents[2] / "sources.lock.json").read_text())["geniex_htp"]
        for name, digest in release["files"].items():
            if hashlib.sha256((args.ops / name).read_bytes()).hexdigest() != digest:
                raise ValueError(f"SHA-256 mismatch for {name}")
        note(f"Signed {release['version']}; HTP0 Target/Draft/audio, Q4 draft, ubatch 512, "
             "OPFUSION=1, position broadcast off. Four AB/BA warm pairs per clip.")
        for block in range(5):
            profile = block == 0
            # Within each pair both arms receive the same two warmups and request order.
            arms = ARMS if block == 0 or block % 2 else ARMS[::-1]
            order = CLIPS if block == 0 or block % 2 else CLIPS[::-1]
            schedule = [("warmup", clip) for clip in CLIPS]
            if not profile:
                schedule += [("timed", clip) for clip in order]
            for arm in arms:
                label = f"conv-layout-{arm}-{'profile' if profile else 'block' + str(block)}"
                log = args.logs / (label + ".stderr.log")
                env = {"VOXT_AUDIO_CONV_LAYOUT": str(int(arm == "view")), "VOXT_AUDIO_POS_BROADCAST": "0",
                       "GGML_HEXAGON_OPFUSION": "1"}
                note(f"Running {label}")
                with suite.server(args, True, profile, 512, log, extra_env=env) as (port, _):
                    for phase, clip in schedule:
                        row = suite.request(port, samples[clip])
                        write_row(rows, dict(arm=arm, block=block, clip=clip, phase=phase, profile=profile, **row))
                        sequence = (row["meta"]["token_ids"], row["text"])
                        if sequences.setdefault(clip, sequence) != sequence:
                            raise ValueError(f"{label}/{clip}: complete tokens or transcript changed")
                        if row["meta"]["proposed_draft_token_count"] <= 0 or (row["htp_events"] > 0) != profile:
                            raise ValueError(f"{label}/{clip}: unexpected draft activity or encoder profiling state")
                        if phase == "timed":
                            warm[block, arm, clip] = row
                devices, batches, _ = suite.log_evidence(log)
                if set(devices) != {"HTP0"} or len(devices) < 2 or batches[:1] != [512]:
                    raise ValueError(f"{label}: devices {devices}, ubatch {batches}")
                if profile:
                    groups = read_profiles(log)
                    if len(groups) != len(CLIPS):
                        raise ValueError(f"{label}: expected {len(CLIPS)} request traces, found {len(groups)}")
                    for clip, trace in zip(CLIPS, groups):
                        write_row(profiles, dict(arm=arm, clip=clip, ops=trace))
                        count, layouts = check_path(trace, arm)
                        if baseline_layouts.setdefault(clip, layouts) != layouts:
                            raise ValueError(f"{clip}: HTP convolution output shapes or multiplicities differ")
                        pack = [r for r in trace if any(t[0] == "pack" for t in r["tags"])]
                        packed_bytes = 4 * sum(prod(key[1:]) * n for key, n in layouts.items()) if pack else 0
                        col_us = [sum(r["dsp_us"] for r in trace if r["im2col_layer"] == layer) for layer in (1, 2, 3)]
                        note(f"{arm}/{clip}: HTP IM2COL={count} (layer 1/2/3 us {col_us[0]}/{col_us[1]}/{col_us[2]}), "
                             f"output packs={len(pack)} ({sum(r['dsp_us'] for r in pack)} us, {packed_bytes} output bytes)")
        for clip in CLIPS:
            for field in ("encoder_ms", "ms"):
                baseline, candidate = ([warm[b, arm, clip][field] for b in range(1, 5)] for arm in ARMS)
                ratios = [a / b for a, b in zip(baseline, candidate)]
                note(f"{clip} {field}: packed/view warm medians {median(baseline):.1f}/{median(candidate):.1f} ms; "
                     f"paired median speedup {median(ratios):.3f}x, view faster in {sum(r > 1 for r in ratios)}/4; "
                     "pair ratios " + "/".join(f"{r:.3f}" for r in ratios))
        note("PASS | signed HTP convolution paths and complete token/text parity verified for both clips.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for key in ("server", "assets", "ops", "logs"):
        parser.add_argument("--" + key, type=Path, required=True)
    options = parser.parse_args()
    try:
        measure(options)
    except Exception as exc:
        options.logs.mkdir(parents=True, exist_ok=True)
        with (options.logs / "htp-conv-layout-summary.txt").open("a", encoding="utf-8") as out:
            print(f"INCOMPLETE: {exc}", file=out)
        raise

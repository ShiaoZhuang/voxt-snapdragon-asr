"""Measure Qwen3-ASR convolution layout on the signed v73 HTP runtime."""
import argparse
from collections import Counter
from contextlib import nullcontext
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
SLOT_RELEASE = re.compile(r"slot\s+release:.*\bstop processing: n_tokens =")


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
                fields = match[0].split("|")
                groups[-1].append(dict(op=op, tensors=tensors, dims=dims, types=fields[3], strides=fields[4],
                                       dsp_us=int(usec), im2col_layer=int(weight[1]) if weight else None, tags=tags))
    return groups


def tensor_descriptors(row):
    """Return (shape, byte strides, dtype) in the same input/output order as htp_format_op."""
    sections = [row[k].split(" -> ") for k in ("dims", "strides", "types")]
    result = []
    for side in (0, 1):
        dims, strides, types = [fields[side].split(" x ") for fields in sections]
        if len(dims) != len(strides) or len(dims) != len(types):
            raise ValueError(f"incomplete tensor descriptors: {row}")
        tensors = []
        for ne, nb, dtype in zip(dims, strides, types):
            shape = tuple(map(int, ne.split(":")))
            steps = tuple(map(int, nb.removesuffix("!").split(":")))
            if len(shape) not in (2, 4) or len(shape) != len(steps) or min(shape) <= 0:
                raise ValueError(f"invalid profile tensor {ne}, {nb}: {row}")
            tensors.append((shape + (1,) * (4 - len(shape)), steps, dtype))
        result.append(tensors)
    return result


def descriptor(shape, dtype="f32", strides=None):
    if strides is None:
        size = {"f16": 2, "f32": 4}[dtype]
        strides = tuple(size * prod(shape[:i]) for i in range(4))
    # htp-opnode.cpp prints only two strides when the last two axes are singletons.
    return shape, strides[:2] if shape[2:] == (1, 1) else strides, dtype


def conv_view_strides(w, h, chunks):
    # Logical [W,H,C,N] view of a physically contiguous [W,H,N,C] F32 tensor.
    return (4, 4 * w, 4 * w * h * chunks, 4 * w * h)


def gelu_launch_shape(w, h, chunks, channels):
    # htp_collapse_dims in e412c6f4. For these three convolution outputs the channel
    # count already exceeds n_hvx, so the later low-parallelism row split never applies.
    a, b, c, d = w, h, chunks, channels
    while (b, c, d) != (1, 1, 1) and (b == 1 or (4 * a < 128 and 4 * a * b <= 2048)):
        a, b, c, d = a * b, c, d, 1
    if b > 1 and 4 * a < 128:
        group = min(b, 2048 // (4 * a))
        while b % group:
            group -= 1
        a, b = a * group, b // group
    return a, b, c, d


def check_path(records, arm):
    counts = {kind: Counter() for kind in ("pack", "cols", "layout_act")}
    layouts, expected, observed = Counter(), Counter(), Counter()
    columns = Counter()
    for row in records:
        inputs, outputs = tensor_descriptors(row)
        layer = row["im2col_layer"]
        if layer:
            # IM2COL descriptors keep the graph dimensions. Its weight is [KW,KH,IC,OC],
            # input is [IW,IH,IC,N], and the columns are [KW*KH*IC,OW,OH,N].
            (kw, kh, cin, cout), _, weight_type = inputs[0]
            iw, ih, _, chunks = inputs[1][0]
            w, h = (iw + 1) // 2, (ih + 1) // 2
            if (kw, kh) != (3, 3) or (iw, ih) != ((100, 128), (50, 64), (25, 32))[layer - 1]:
                raise ValueError(f"{arm} layer {layer} unexpected IM2COL weight or input dimensions: {row['dims']}")
            steps = conv_view_strides(iw, ih, chunks) if arm == "view" and layer > 1 else None
            data = descriptor((iw, ih, cin, chunks), strides=steps)
            cols = descriptor((kw * kh * cin, w, h, chunks), "f32" if weight_type == "bf16" else "f16")
            if inputs[1] != data or outputs != [cols]:
                raise ValueError(f"{arm} layer {layer} IM2COL expected input/output {data}, {cols}; "
                                 f"observed {inputs[1]}, {outputs}")
            logical = (w, h, cout, chunks)
            layouts[(layer, *logical)] += 1
            columns[layer] += 1
            if arm == "packed":
                expected[layer, descriptor(logical, strides=conv_view_strides(w, h, chunks)), descriptor(logical)] += 1
            else:
                launch = descriptor(gelu_launch_shape(w, h, chunks, cout))
                expected[layer, launch, launch] += 1
        for kind, layer, _ in row["tags"]:
            counts[kind][layer] += 1
            if not PRODUCERS[kind].intersection(row["op"].split("+")) or (kind == "cols" and layer != row["im2col_layer"]):
                raise ValueError(f"unexpected HTP producer for layer {layer}: {row}")
            if kind != "cols":
                names = row["tensors"].rpartition(" -> ")[2].split(" x ")
                out = outputs[names.index(f"voxt_conv_{kind}-{layer}")]
                observed[layer, inputs[0], out] += 1
    kinds = {"pack"} if arm == "packed" else {"cols", "layout_act"}
    if {k for k, v in counts.items() if v} != kinds:
        raise ValueError(f"{arm}: unexpected or missing HTP path, layer tags {counts}")
    if set(columns) != LAYERS or len(set(columns.values())) != 1 or any(counts[k] != columns for k in kinds):
        raise ValueError(f"{arm}: incomplete HTP convolution evidence, {counts}, IM2COL={columns}")
    if expected != observed:
        raise ValueError(f"{arm}: convolution launch descriptors differ (layer, input, output); "
                         f"expected only {dict(expected - observed)}; observed only {dict(observed - expected)}")
    return sum(columns.values()), layouts


def archived_requests(directory, samples):
    """Load just the four diagnostic requests. Timings always come from fresh runs."""
    records = {}
    with (directory / "htp-conv-layout.jsonl").open(encoding="utf-8-sig") as src:
        for line in src:
            row = json.loads(line)
            if row["block"] != 0:
                continue
            arm, clip, meta = row["arm"], row["clip"], row["meta"]
            _, duration, language, reference = samples[clip]
            ids = meta["token_ids"]
            if (not row["profile"] or row["phase"] != "warmup" or arm not in ARMS or clip not in CLIPS
                    or (arm, clip) in records or meta["finish_reason"] != "stop" or not ids
                    or not isinstance(ids, list) or any(type(item) is not int for item in ids)
                    or not 0 < meta["generated_token_count"] <= len(ids) <= meta["generated_token_count"] + 1
                    or not row["text"] or meta["proposed_draft_token_count"] <= 0 or row["htp_events"] <= 0
                    or row["htp_events"] != meta["audio_encoder_htp_events"]
                    or (row["duration"], row["language"], row["reference"]) != (duration, language, reference)):
                raise ValueError(f"unusable archived profile response for {arm}/{clip}")
            records[arm, clip] = row
    if list(records) != [(arm, clip) for arm in ARMS for clip in CLIPS]:
        raise ValueError("missing or out-of-order archived profile responses")
    for arm in ARMS:
        path = directory / f"conv-layout-{arm}-profile.stderr.log"
        boundaries = []
        with path.open(encoding="utf-8", errors="replace") as src:
            for line in src:
                if REQUEST_START in line:
                    boundaries.append("begin")
                elif boundaries and boundaries[-1] == "begin" and SLOT_RELEASE.search(line):
                    boundaries.append("end")
        if boundaries != ["begin", "end"] * len(CLIPS):
            raise ValueError(f"incomplete archived requests in {path.name}: {boundaries}")
    return records


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
        archive = getattr(args, "profile_archive", None)
        saved = {}
        if archive:
            try:
                saved = archived_requests(archive, samples)
                note(f"Rechecking both archived HTP profiles from {archive}")
            except (OSError, ValueError, TypeError, KeyError) as exc:
                note(f"Archive unavailable ({exc}); collecting both HTP profiles.")
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
                replay = profile and bool(saved)
                log = (archive if replay else args.logs) / (label + ".stderr.log")
                env = {"VOXT_AUDIO_CONV_LAYOUT": str(int(arm == "view")), "VOXT_AUDIO_POS_BROADCAST": "0",
                       "GGML_HEXAGON_OPFUSION": "1"}
                note(f"{'Reading' if replay else 'Running'} {label}")
                session = nullcontext((None, None)) if replay else suite.server(args, True, profile, 512, log, extra_env=env)
                with session as (port, _):
                    for phase, clip in schedule:
                        row = saved[arm, clip] if replay else suite.request(port, samples[clip])
                        write_row(rows, dict(row, arm=arm, block=block, clip=clip, phase=phase, profile=profile))
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
                            raise ValueError(f"{clip}: logical convolution layouts differ (layer,W,H,C,N); "
                                             f"packed only {dict(baseline_layouts[clip] - layouts)}; "
                                             f"view only {dict(layouts - baseline_layouts[clip])}")
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
    parser.add_argument("--profile-archive", type=Path, help="recheck completed diagnostic runs from 79c8ac8")
    options = parser.parse_args()
    try:
        measure(options)
    except Exception as exc:
        options.logs.mkdir(parents=True, exist_ok=True)
        with (options.logs / "htp-conv-layout-summary.txt").open("a", encoding="utf-8") as out:
            print(f"INCOMPLETE: {exc}", file=out)
        raise

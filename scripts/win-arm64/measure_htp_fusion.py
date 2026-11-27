"""Measure signed v73 operator fusion and Qwen3-ASR chunk-position broadcast on HTP0."""
import argparse
import hashlib
import json
from pathlib import Path
import re
from statistics import median

import measure_htp_suite as suite


# e412c6f4 htp-fusion.h: 0 disables graph fusion and 1 enables all rules.
ARMS = {"unfused": (0, 0), "fused": (1, 0), "broadcast": (1, 1)}
CLIPS = (suite.SEED, "long-zh")
REQUEST_START = "voxt: GGML Hexagon audio request started"
PROFILE_OP = re.compile(r"ggml-hex: HTP0 profile-op ([^| ]+)\|([^|]*)\|([^|]*)\|.*?\|usec (\d+) cycles (\d+)\b")
STACKED = {"MUL_MAT_NX", "MUL_MAT_ID_NX", "ADD_NX", "SUB_NX", "MUL_NX", "DIV_NX"}


def write_row(file, row):
    file.write(json.dumps(row, ensure_ascii=False) + "\n")
    file.flush()


def read_profiles(path):
    """Count completed HTP commands by final fused name, excluding startup and batch records."""
    groups = []
    with path.open(encoding="utf-8", errors="replace") as src:
        for line in src:
            if REQUEST_START in line:
                groups.append({"commands": 0, "fused": {}, "position": {}})
                continue
            if not groups or "HTP0 profile-op" not in line:
                continue
            match = PROFILE_OP.search(line)
            if not match:
                continue
            name, tensors, shapes, us, cycles = match.groups()
            if name == "OPBATCH" or int(cycles) == 0:
                continue
            group = groups[-1]
            group["commands"] += 1
            # htp_opnode::name joins graph ops with '+', except for CPY+FENCE.
            # A graph-native SWIGLU/FLASH_ATTN_EXT is already one GGML op.
            if name in STACKED or ("+" in name and name != "CPY+FENCE"):
                stat = group["fused"].setdefault(name, {"count": 0, "dsp_us": 0, "example": tensors})
                stat["count"] += 1
                stat["dsp_us"] += int(us)
            outputs = tensors.rpartition(" -> ")[2].split(" x ")
            for tag, kind in (("voxt_pos_repeat", "repeat"), ("voxt_pos_broadcast_add", "broadcast")):
                if tag in outputs:
                    stat = group["position"].setdefault(kind, {"count": 0, "dsp_us": 0, "example": tensors, "shapes": shapes, "op": name})
                    stat["count"] += 1
                    stat["dsp_us"] += int(us)
    return groups


def profile_checks(group, arm):
    errors = []
    if not group["commands"]:
        errors.append("no completed HTP0 commands")
    if bool(group["fused"]) != bool(ARMS[arm][0]):
        errors.append("fused command counts disagree with OPFUSION")
    expected = "broadcast" if arm == "broadcast" else "repeat"
    if set(group["position"]) != {expected}:
        errors.append(f"HTP0 execution of {expected} unverified; observed {list(group['position'])}")
    return errors


def measure(args):
    args.logs.mkdir(parents=True, exist_ok=True)
    summary = args.logs / "htp-fusion-summary.txt"
    summary.write_text("", encoding="utf-8")

    def note(line):
        print(line, flush=True)
        with summary.open("a", encoding="utf-8") as f:
            print(line, file=f)

    release = json.loads((Path(__file__).resolve().parents[2] / "sources.lock.json").read_text())["geniex_htp"]
    for filename, expected in release["files"].items():
        if hashlib.sha256((args.ops / filename).read_bytes()).hexdigest() != expected:
            raise ValueError(f"SHA-256 mismatch for {filename} in {args.ops}")
    note(f"Q4 DFlash, Target/Draft/audio HTP0; signed GenieX {release['version']}; ubatch 512.")
    samples = suite.load_samples(args.assets / "eval")
    sequences, times = {}, {}
    issues = {arm: [] for arm in ARMS}
    with (args.logs / "htp-fusion.jsonl").open("w", encoding="utf-8") as rows, \
         (args.logs / "htp-fusion-profile.jsonl").open("w", encoding="utf-8") as profiles:
        arms = list(ARMS)
        for block in range(suite.TRIALS + 1):
            profile = block == 0
            # Each arm occupies each time slot once. Warm each clip on every new server.
            offset = max(0, block - 1) % len(arms)
            for arm in arms[offset:] + arms[:offset]:
                opfusion, broadcast = ARMS[arm]
                label = f"fusion-{arm}-{'profile' if profile else f'block{block}'}"
                log = args.logs / (label + ".stderr.log")
                schedule = [(0, clip) for clip in CLIPS]
                if not profile:
                    schedule.extend((block, clip) for clip in (CLIPS if block % 2 else reversed(CLIPS)))
                env = {"GGML_HEXAGON_OPFUSION": str(opfusion), "VOXT_AUDIO_POS_BROADCAST": str(broadcast)}
                note(f"Running {label}")
                try:
                    with suite.server(args, True, profile, 512, log, extra_env=env) as (port, _):
                        for rep, clip in schedule:
                            result = suite.request(port, samples[clip])
                            write_row(rows, dict(arm=arm, block=block, profile=profile, clip=clip, rep=rep, **result))
                            meta = result["meta"]
                            sequence = (meta["token_ids"], result["text"])
                            if sequences.setdefault(clip, sequence) != sequence:
                                issues[arm].append(f"{label}/{clip}: token or transcript mismatch")
                            if meta["proposed_draft_token_count"] <= 0 or (profile and result["htp_events"] <= 0):
                                issues[arm].append(f"{label}/{clip}: missing DFlash or audio HTP evidence")
                            if rep:
                                times.setdefault((arm, clip), []).append(result)
                    devices, batches, _ = suite.log_evidence(log)
                    if set(devices) != {"HTP0"} or len(devices) < 2 or batches[:1] != [512]:
                        issues[arm].append(f"{label}: logged devices {devices}, ubatch {batches}")
                    if profile:
                        groups = read_profiles(log)
                        if len(groups) != len(schedule):
                            raise ValueError(f"expected {len(schedule)} request traces, found {len(groups)}")
                        for (_, clip), group in zip(schedule, groups):
                            write_row(profiles, dict(arm=arm, clip=clip, **group))
                            issues[arm].extend(f"{label}/{clip}: {e}" for e in profile_checks(group, arm))
                            counts = ", ".join(f"{name}={v['count']}" for name, v in sorted(group["fused"].items()))
                            pos = ", ".join(f"{op}={v['count']}" for op, v in group["position"].items())
                            note(f"{arm}/{clip}: {group['commands']} HTP commands; fused [{counts}]; position [{pos}]")
                except Exception as exc:
                    message = f"{label}: {exc}"
                    issues[arm].append(message)
                    note("FAIL " + message)

    for clip in CLIPS:
        for base, candidate in (("unfused", "fused"), ("fused", "broadcast")):
            pair = [times.get((arm, clip), []) for arm in (base, candidate)]
            if any(len(group) != suite.TRIALS for group in pair):
                continue
            ms = [median(r["ms"] for r in group) for group in pair]
            encoder = [median(r["encoder_ms"] for r in group) for group in pair]
            valid = "verified" if not issues[base] and not issues[candidate] else "unverified"
            note(f"{clip} {base}/{candidate} ({valid}): warm median request {ms[0]:.1f}/{ms[1]:.1f} ms "
                 f"({ms[0]/ms[1]:.3f}x), encoder {encoder[0]:.1f}/{encoder[1]:.1f} ms")
    errors = sorted({message for arm_issues in issues.values() for message in arm_issues})
    if errors:
        raise RuntimeError("; ".join(errors))
    note("PASS | signed v73 fusion execution, positional-op placement and exact transcript/token parity.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for key in ("server", "assets", "ops", "logs"):
        parser.add_argument("--" + key, type=Path, required=True)
    args = parser.parse_args()
    try:
        measure(args)
    except Exception as exc:
        with (args.logs / "htp-fusion-summary.txt").open("a", encoding="utf-8") as report:
            print(f"INCOMPLETE: {exc}", file=report)
        raise

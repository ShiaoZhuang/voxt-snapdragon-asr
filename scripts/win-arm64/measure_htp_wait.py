"""Compare FastRPC completion waiting with polling, including server CPU cost."""
import argparse
import ctypes
from ctypes import wintypes
import json
from pathlib import Path
from statistics import median

from measure_htp_suite import SEED, load_samples, log_evidence, request, server


class ProcessCpu:
    def __init__(self, pid):
        self.api = ctypes.WinDLL("kernel32", use_last_error=True)
        self.api.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
        self.api.OpenProcess.restype = wintypes.HANDLE
        self.api.GetProcessTimes.argtypes = [wintypes.HANDLE] + [ctypes.POINTER(wintypes.FILETIME)] * 4
        self.api.GetProcessTimes.restype = wintypes.BOOL
        self.api.CloseHandle.argtypes = [wintypes.HANDLE]
        self.handle = self.api.OpenProcess(0x1000, False, pid)  # PROCESS_QUERY_LIMITED_INFORMATION
        if not self.handle:
            raise ctypes.WinError(ctypes.get_last_error())

    def milliseconds(self):
        values = [wintypes.FILETIME() for _ in range(4)]
        if not self.api.GetProcessTimes(self.handle, *(ctypes.byref(v) for v in values)):
            raise ctypes.WinError(ctypes.get_last_error())
        # Kernel and user time are accumulated across all server threads, in units of 100 ns.
        return sum((v.dwHighDateTime << 32) + v.dwLowDateTime for v in values[2:]) / 10000

    def close(self):
        self.api.CloseHandle(self.handle)


def measure(args):
    samples = load_samples(args.assets / "eval")
    names = [SEED, "long-all"]
    reference = {}
    rows = []
    notes = args.logs / "htp-wait-summary.txt"

    def note(message):
        print(message, flush=True)
        with notes.open("a", encoding="utf-8") as out:
            print(message, file=out)

    notes.write_text("", encoding="utf-8")
    note("FastRPC wait/poll | all HTP Q4 DFlash | wall time and server CPU time")
    with (args.logs / "htp-wait.jsonl").open("w", encoding="utf-8") as out:
        # Confirm the selected graph uses HTP on the same audio, outside the timed A/B.
        proof = args.logs / "proof.log"
        with server(args, True, True, 512, proof) as (port, _):
            for name in names:
                r = request(port, samples[name])
                if not r["htp_events"] or not r["meta"]["proposed_draft_token_count"]:
                    raise ValueError(f"{name}: missing encoder HTP events or draft proposals")
                reference[name] = r["meta"]["token_ids"], r["text"]
        devices, _, ops = log_evidence(proof)
        if len(devices) < 2 or set(devices) != {"HTP0"} or not ops:
            raise ValueError(f"missing HTP evidence in {proof.name}")

        # ABBA balances a monotonic temperature or background-load trend across launches.
        for idx, poll in enumerate((0, 1, 1, 0)):
            log = args.logs / f"run-{idx}-poll{poll}.log"
            with server(args, True, False, 512, log, extra_env={"GGML_HEXAGON_OPPOLL": str(poll)}, with_pid=True) as (port, _, pid):
                cpu = ProcessCpu(pid)
                try:
                    request(port, samples[SEED])
                    for rep in range(2):
                        for name in (names if rep == 0 else reversed(names)):
                            print(f"[voxt] Wait/poll {idx+1}/4, poll={poll}, {name}, rep {rep+1}", flush=True)
                            before = cpu.milliseconds()
                            r = request(port, samples[name])
                            r.update(cpu_ms=cpu.milliseconds()-before, poll=poll, launch=idx, rep=rep+1, clip=name)
                            out.write(json.dumps(r, ensure_ascii=False) + "\n")
                            out.flush()
                            if reference[name] != (r["meta"]["token_ids"], r["text"]):
                                raise ValueError(f"{name}: token sequence or transcript changed at poll={poll}")
                            rows.append(r)
                finally:
                    cpu.close()
            devices, _, _ = log_evidence(log)
            if len(devices) < 2 or set(devices) != {"HTP0"}:
                raise ValueError(f"{log.name}: unexpected backend {devices}")

    for name in names:
        by_poll = [[r for r in rows if r["clip"] == name and r["poll"] == poll] for poll in (0, 1)]
        wall = [median(r["ms"] for r in group) for group in by_poll]
        cpu = [median(r["cpu_ms"] for r in group) for group in by_poll]
        note(f"{name} wait/poll | median wall {wall[0]:.0f}/{wall[1]:.0f} ms ({wall[0]/wall[1]:.2f}x) | median CPU {cpu[0]:.0f}/{cpu[1]:.0f} ms")
    note("PASS | identical tokens and transcripts | 4 warm measurements per mode and clip")


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__)
    for arg in ("server", "assets", "ops", "logs"):
        p.add_argument("--" + arg, required=True, type=Path)
    args = p.parse_args()
    try:
        measure(args)
    except Exception as exc:
        with (args.logs / "htp-wait-summary.txt").open("a", encoding="utf-8") as out:
            print(f"INCOMPLETE: {exc}", file=out)
        raise

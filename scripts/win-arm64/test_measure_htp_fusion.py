import contextlib
import io
import json
from pathlib import Path
from tempfile import TemporaryDirectory
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import measure_htp_fusion as fusion


def command(name, tensors="w x inp -> result", us=3, cycles=9):
    return f"ggml-hex: HTP0 profile-op {name}|{tensors}|13312:1 x 13312:4 -> 13312:4|f32|stride|kernel|usec {us} cycles {cycles} start 0\n"


class FusionProfileTests(unittest.TestCase):
    def test_completed_requests_only(self):
        with TemporaryDirectory() as tmp:
            path = Path(tmp, "stderr.log")
            path.write_text(command("RMS_NORM+MUL") + fusion.REQUEST_START + "\n"
                            + command("RMS_NORM+MUL", cycles=0) + command("OPBATCH") + command("CPY+FENCE")
                            + command("SWIGLU") + command("RMS_NORM+MUL") * 2 + command("MUL_MAT_NX")
                            + command("ADD", "in x row -> voxt_pos_broadcast_add")
                            + fusion.REQUEST_START + "\n" + command("REPEAT", "pos -> voxt_pos_repeat")
                            + command("SWIGLU", "voxt_pos_broadcast_add x in -> used"))
            a, b = fusion.read_profiles(path)
        self.assertEqual(a["commands"], 6)
        self.assertEqual(set(a["fused"]), {"RMS_NORM+MUL", "MUL_MAT_NX"})
        self.assertEqual(a["fused"]["RMS_NORM+MUL"]["count"], 2)
        self.assertEqual(a["fused"]["RMS_NORM+MUL"]["dsp_us"], 6)
        self.assertEqual(fusion.profile_checks(a, "broadcast"), [])
        self.assertEqual(fusion.profile_checks(b, "unfused"), [])
        self.assertTrue(fusion.profile_checks(b, "broadcast"))
        self.assertTrue(fusion.profile_checks(a, "unfused"))

    def simulate(self, root, *, missing_broadcast=False, changed_token=False):
        active = {}

        @contextlib.contextmanager
        def server(args, draft, profile, ubatch, path, *, extra_env):
            self.assertTrue(draft)
            self.assertEqual(ubatch, 512)
            values = tuple(map(int, (extra_env["GGML_HEXAGON_OPFUSION"], extra_env["VOXT_AUDIO_POS_BROADCAST"])))
            active.update(values=values, profile=profile, log=path)
            path.write_text("llama_prepare_model_devices: using device HTP0 test\n" * 2 + "n_ubatch = 512\n")
            yield 1234, 1

        def request(port, sample):
            enabled, broadcast = active["values"]
            with active["log"].open("a") as log:
                print(fusion.REQUEST_START, file=log)
                if active["profile"]:
                    log.write(command("RMS_NORM+MUL" if enabled else "RMS_NORM"))
                    if not broadcast or not missing_broadcast:
                        log.write(command("ADD", "x x pos -> voxt_pos_broadcast_add") if broadcast else
                                  command("REPEAT", "pos -> voxt_pos_repeat"))
            return {"meta": {"token_ids": [1 if not (changed_token and broadcast) else 2], "proposed_draft_token_count": 2},
                    "text": "test", "ms": 1, "encoder_ms": .1, "htp_events": int(active["profile"])}

        args = SimpleNamespace(logs=root, assets=root, ops=root, server=None)
        # Supply deterministic digests to the package gate; remaining I/O follows the real runner.
        release = root / "sources.lock.json"
        (root / "v73.so").write_bytes(b"")
        release.write_text(json.dumps({"geniex_htp": {"version": "fixture", "files":
            {"v73.so": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"}}}))
        with patch.object(fusion, "__file__", str(root / "scripts/win-arm64/fixture.py")), \
             patch.object(fusion.suite, "load_samples", return_value={k: k for k in fusion.CLIPS}), \
             patch.object(fusion.suite, "server", server), patch.object(fusion.suite, "request", request), \
             contextlib.redirect_stdout(io.StringIO()):
            fusion.measure(args)

    def test_all_arms_and_counterbalanced_warm_trials(self):
        with TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.simulate(root)
            rows = [json.loads(line) for line in (root / "htp-fusion.jsonl").read_text().splitlines()]
            for arm in fusion.ARMS:
                for clip in fusion.CLIPS:
                    selected = [r for r in rows if r["arm"] == arm and r["clip"] == clip and r["rep"]]
                    self.assertEqual([r["rep"] for r in selected], [1, 2, 3])
                    self.assertTrue(all(not r["profile"] for r in selected))
            self.assertIn("PASS", (root / "htp-fusion-summary.txt").read_text())

    def test_incomplete_placement_and_token_mismatch(self):
        for options, message in (({"missing_broadcast": True}, "execution of broadcast unverified"),
                                 ({"changed_token": True}, "token or transcript mismatch")):
            with self.subTest(options=options), TemporaryDirectory() as tmp:
                root = Path(tmp)
                with self.assertRaisesRegex(RuntimeError, message):
                    self.simulate(root, **options)
                report = (root / "htp-fusion-summary.txt").read_text()
                self.assertIn("fused/broadcast (unverified)", report)
                self.assertIn("unfused/fused (verified)", report)
                self.assertNotIn("PASS", report)


if __name__ == "__main__":
    unittest.main()

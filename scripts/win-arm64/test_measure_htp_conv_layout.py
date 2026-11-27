import contextlib
import hashlib
import io
import json
from pathlib import Path
from tempfile import TemporaryDirectory
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import measure_htp_conv_layout as conv


def command(op, inputs, output, shape="50:64:480:7", cycles=3):
    return (f"ggml-hex: HTP0 profile-op {op}|{inputs} -> {output}|w x inp -> {shape}"
            f"|f32|strides|kernel|usec 1 cycles {cycles} start 0\n")


def trace(view, *, drop_layer=False):
    lines = [conv.REQUEST_START + "\n", command("IM2COL", "other.weight", "other")]
    for layer in (1, 2, 3):
        weight = f"a.conv2d.{layer}.weight x input"
        lines.append(command("IM2COL", weight, f"voxt_conv_cols-{layer}" if view else "col"))
        if view:
            cycles = 0 if drop_layer and layer == 3 else 3
            lines.append(command("GELU_ERF", "x", f"voxt_conv_layout_act-{layer}", "50:64:7:480", cycles))
        else:
            lines.append(command("CONT", "x", f"voxt_conv_pack-{layer}"))
    return "".join(lines)


class ConvLayoutTests(unittest.TestCase):
    def test_profile_layers_and_wrong_path(self):
        with TemporaryDirectory() as tmp:
            path = Path(tmp, "trace.log")
            path.write_text(command("CONT", "x", "voxt_conv_pack-1") + trace(False) + trace(True) +
                            trace(True, drop_layer=True))
            packed, view, incomplete = conv.read_profiles(path)
            self.assertEqual(conv.check_path(packed, "packed"), conv.check_path(view, "view"))
            with self.assertRaisesRegex(ValueError, "missing HTP path"):
                conv.check_path(packed, "view")
            with self.assertRaisesRegex(ValueError, "incomplete HTP convolution"):
                conv.check_path(incomplete, "view")

    def simulate(self, root, *, change_tokens=False, change_shape=False):
        active = {}
        @contextlib.contextmanager
        def server(args, draft, profile, ubatch, log, *, extra_env):
            self.assertTrue(draft)
            self.assertEqual(ubatch, 512)
            self.assertEqual(extra_env["VOXT_AUDIO_POS_BROADCAST"], "0")
            self.assertEqual(extra_env["GGML_HEXAGON_OPFUSION"], "1")
            active.update(view=extra_env["VOXT_AUDIO_CONV_LAYOUT"] == "1", profile=profile, log=log)
            log.write_text("llama_prepare_model_devices: using device HTP0 test\n" * 2 + "n_ubatch = 512\n")
            yield 1234, 0

        def request(port, clip):
            view = active["view"]
            with active["log"].open("a") as log:
                if active["profile"]:
                    msg = trace(view)
                    if change_shape and view:
                        msg = msg.replace("50:64:7:480", "50:64:6:480")
                    log.write(msg)
            return dict(meta={"token_ids": [1 + int(view and change_tokens)], "proposed_draft_token_count": 3},
                        text=clip, htp_events=int(active["profile"]), ms=2 if view else 4, encoder_ms=1 if view else 2)

        root.joinpath("v73.so").write_bytes(b"fixture")
        root.joinpath("sources.lock.json").write_text(json.dumps({"geniex_htp": {"version": "fixture",
            "files": {"v73.so": hashlib.sha256(b"fixture").hexdigest()}}}))
        args = SimpleNamespace(logs=root, ops=root, assets=root)
        with patch.object(conv, "__file__", str(root/"scripts/win-arm64/fixture.py")), \
             patch.object(conv.suite, "load_samples", return_value={c: c for c in conv.CLIPS}), \
             patch.object(conv.suite, "server", server), patch.object(conv.suite, "request", request), \
             contextlib.redirect_stdout(io.StringIO()):
            conv.measure(args)

    def test_balanced_warm_pairs(self):
        with TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.simulate(root)
            rows = [json.loads(line) for line in (root/"htp-conv-layout.jsonl").read_text().splitlines()]
            self.assertEqual(len(rows), 36)
            for clip in conv.CLIPS:
                measured = [r for r in rows if r["phase"] == "timed" and r["clip"] == clip]
                self.assertEqual([r["arm"] for r in measured],
                                 ["packed", "view", "view", "packed"] * 2)
                self.assertFalse(any(r["profile"] for r in measured))
            summary = (root/"htp-conv-layout-summary.txt").read_text()
            self.assertEqual(summary.count("paired median speedup 2.000x, view faster in 4/4"), 4)
            self.assertIn("PASS |", summary)

    def test_token_and_shape_drift_fail(self):
        for options, error in [({"change_tokens": True}, "tokens or transcript"),
                               ({"change_shape": True}, "output shapes")]:
            with self.subTest(options=options), TemporaryDirectory() as tmp:
                with self.assertRaisesRegex(ValueError, error):
                    self.simulate(Path(tmp), **options)
                self.assertNotIn("PASS |", Path(tmp, "htp-conv-layout-summary.txt").read_text())


if __name__ == "__main__":
    unittest.main()

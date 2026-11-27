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


def tensor(name, dims, dtype="f32", steps=None):
    if steps is None:
        stride = 2 if dtype == "f16" else 4
        steps = []
        for extent in dims:
            steps.append(stride)
            stride *= extent
    n = 2 if tuple(dims[2:]) == (1, 1) else 4
    return (name, ":".join(map(str, dims[:n])), dtype, ":".join(map(str, steps[:n])))


def command(op, inputs, output, cycles=3):
    fields = "|".join(" x ".join(t[k] for t in inputs) + " -> " + output[k] for k in range(4))
    return f"ggml-hex: HTP0 profile-op {op}|{fields}|kernel|usec 1 cycles {cycles} start 0\n"


def trace(view, *, drop_layer=False, chunks=7):
    other = tensor("other.weight", (4, 4, 1, 1))
    lines = [conv.REQUEST_START + "\n", command("IM2COL", [other], other)]
    for layer, (iw, ih, w, h, cin) in enumerate(((100,128,50,64,1), (50,64,25,32,480), (25,32,13,16,480)), 1):
        # At this revision htp_collapse_dims leaves L1 alone, folds sixteen of
        # L2's 32 rows, and folds all 16 rows at L3. N=1 drops another singleton.
        view_shapes = [(50,64,chunks,480), (400,2,chunks,480),
                       (208,chunks,480,1) if chunks > 1 else (208,480,1,1)]
        raw_steps = (4, 4*iw, 4*iw*ih*chunks, 4*iw*ih) if view and layer > 1 else None
        weight = tensor(f"a.conv2d.{layer}.weight", (3,3,cin,480), "f16")
        data = tensor("input", (iw,ih,cin,chunks), steps=raw_steps)
        cols = tensor(f"voxt_conv_cols-{layer}" if view else "col", (9*cin,w,h,chunks), "f16")
        lines.append(command("IM2COL", [weight, data], cols))
        if view:
            shape = view_shapes[layer-1]
            lines.append(command("GELU_ERF", [tensor("x", shape)], tensor(f"voxt_conv_layout_act-{layer}", shape),
                                 cycles=0 if drop_layer and layer == 3 else 3))
        else:
            shape = (w,h,480,chunks)
            steps = (4, 4*w, 4*w*h*chunks, 4*w*h)
            lines.append(command("CONT", [tensor("x", shape, steps=steps)], tensor(f"voxt_conv_pack-{layer}", shape)))
    return "".join(lines)


class ConvLayoutTests(unittest.TestCase):
    def test_profile_layers_and_wrong_path(self):
        with TemporaryDirectory() as tmp:
            path = Path(tmp, "trace.log")
            path.write_text(trace(False) + trace(True) +
                            trace(True, drop_layer=True))
            packed, view, incomplete = conv.read_profiles(path)
            self.assertEqual(conv.check_path(packed, "packed"), conv.check_path(view, "view"))
            with self.assertRaisesRegex(ValueError, "view layer 2 IM2COL"):
                conv.check_path(packed, "view")
            with self.assertRaisesRegex(ValueError, "incomplete HTP convolution"):
                conv.check_path(incomplete, "view")

    def test_launch_descriptors_for_single_chunk_and_multiblock_clips(self):
        with TemporaryDirectory() as tmp:
            path = Path(tmp, "profiles.log")
            for chunks, blocks in ((1,1), (7,1), (8,12)):
                groups = []
                for view in (False, True):
                    block = trace(view, chunks=chunks)
                    path.write_text(block + block.partition("\n")[2] * (blocks-1))
                    group, = conv.read_profiles(path)
                    groups.append(conv.check_path(group, "view" if view else "packed"))
                self.assertEqual(groups[0], groups[1])
                count, layouts = groups[0]
                self.assertEqual(count, 3 * blocks)
                self.assertEqual(layouts[(3,13,16,480,chunks)], blocks)

    def test_wrong_stride_and_same_size_launch_fail(self):
        with TemporaryDirectory() as tmp:
            path = Path(tmp, "profiles.log")
            # Alter the actual IM2COL channel stride or exchange GELU rows/columns
            # while keeping the same number of elements.
            for before, after, diagnostic in [
                ("4:200:89600:12800", "4:200:12800:89600", "layer 2 IM2COL"),
                ("400:2:7:480", "200:4:7:480", "launch descriptors differ"),
                ("4:1600:3200:22400", "4:1600:22400:3200", "launch descriptors differ"),
            ]:
                with self.subTest(before=before):
                    raw = trace(True)
                    self.assertIn(before, raw)
                    path.write_text(raw.replace(before, after))
                    group, = conv.read_profiles(path)
                    with self.assertRaisesRegex(ValueError, diagnostic):
                        conv.check_path(group, "view")

    def simulate(self, root, *, change_tokens=False, change_shape=False, change_chunks=False, archive=None):
        active = {}
        launches = []
        samples = {clip: (b"", 6.0 if idx == 0 else 95.0, "zh", clip) for idx, clip in enumerate(conv.CLIPS)}
        @contextlib.contextmanager
        def server(args, draft, profile, ubatch, log, *, extra_env):
            launches.append(profile)
            self.assertTrue(draft)
            self.assertEqual(ubatch, 512)
            self.assertEqual(extra_env["VOXT_AUDIO_POS_BROADCAST"], "0")
            self.assertEqual(extra_env["GGML_HEXAGON_OPFUSION"], "1")
            active.update(view=extra_env["VOXT_AUDIO_CONV_LAYOUT"] == "1", profile=profile, log=log)
            log.write_text("llama_prepare_model_devices: using device HTP0 test\n" * 2 + "n_ubatch = 512\n")
            yield 1234, 0

        def request(port, sample):
            _, duration, language, clip = sample
            view = active["view"]
            with active["log"].open("a") as log:
                if active["profile"]:
                    msg = trace(view, chunks=8 if view and change_chunks else 7)
                    if change_shape and view:
                        msg = msg.replace("400:2:7:480", "200:4:7:480")
                    log.write(msg + "slot      release: id 0 | task 1 | stop processing: n_tokens = 37\n")
            return dict(meta={"token_ids": [1 + int(view and change_tokens)], "generated_token_count": 1,
                              "finish_reason": "stop", "audio_encoder_htp_events": int(active["profile"]),
                              "proposed_draft_token_count": 3}, duration=duration, language=language, reference=clip,
                        text=clip, htp_events=int(active["profile"]), ms=2 if view else 4, encoder_ms=1 if view else 2)

        root.joinpath("v73.so").write_bytes(b"fixture")
        root.joinpath("sources.lock.json").write_text(json.dumps({"geniex_htp": {"version": "fixture",
            "files": {"v73.so": hashlib.sha256(b"fixture").hexdigest()}}}))
        args = SimpleNamespace(logs=root, ops=root, assets=root, profile_archive=archive)
        with patch.object(conv, "__file__", str(root/"scripts/win-arm64/fixture.py")), \
             patch.object(conv.suite, "load_samples", return_value=samples), \
             patch.object(conv.suite, "server", server), patch.object(conv.suite, "request", request), \
             contextlib.redirect_stdout(io.StringIO()):
            conv.measure(args)
        return launches

    def test_archived_diagnostics_then_new_timing(self):
        with TemporaryDirectory() as tmp:
            archive = Path(tmp, "old")
            archive.mkdir()
            self.simulate(archive)
            raw = archive / "htp-conv-layout.jsonl"
            captured = raw.read_text().splitlines()[:4]
            raw.write_text("\n".join(captured) + "\n")
            # The failed version only wrote three derived profiles. Always parse native stderr.
            (archive / "htp-conv-layout-profile.jsonl").unlink()
            for name, expected_profiles in (("resumed", 0), ("truncated-log", 2), ("missing-response", 2)):
                if name == "truncated-log":
                    path = archive/"conv-layout-view-profile.stderr.log"
                    path.write_text(path.read_text().rsplit("slot      release:", 1)[0])
                if name == "missing-response":
                    raw.write_text("\n".join(captured[:-1]) + "\n")
                fresh = Path(tmp, name)
                fresh.mkdir()
                launches = self.simulate(fresh, archive=archive)
                self.assertEqual(launches.count(True), expected_profiles)
                self.assertEqual(launches.count(False), 8)
                self.assertEqual(len((fresh/"htp-conv-layout-profile.jsonl").read_text().splitlines()), 4)

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
                               ({"change_shape": True}, "launch descriptors differ"),
                               ({"change_chunks": True}, "logical convolution layouts differ")]:
            with self.subTest(options=options), TemporaryDirectory() as tmp:
                with self.assertRaisesRegex(ValueError, error):
                    self.simulate(Path(tmp), **options)
                self.assertNotIn("PASS |", Path(tmp, "htp-conv-layout-summary.txt").read_text())


if __name__ == "__main__":
    unittest.main()

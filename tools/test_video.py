# SPDX-License-Identifier: GPL-2.0-only
import copy
import io
import json
from pathlib import Path
import shutil
import unittest
from unittest.mock import patch
import uuid
import wave

import video


class VideoTests(unittest.TestCase):
    def setUp(self):
        self.directory = video.ROOT / "build/video/tests" / uuid.uuid4().hex
        self.directory.mkdir(parents=True)
        self.path = video.RECIPES / "add-move-resize-panel.json"
        self.recipe = video.load_recipe(self.path)

    def tearDown(self):
        shutil.rmtree(self.directory)

    def validate(self, recipe):
        path = self.directory / "recipe.json"
        path.write_text(json.dumps(recipe))
        shutil.copyfile(self.path.parent / self.recipe["actions"], self.directory / self.recipe["actions"])
        return video.load_recipe(path)

    def wav(self, seconds=.1, rate=48000):
        data = io.BytesIO()
        with wave.open(data, "wb") as file:
            file.setnchannels(1)
            file.setsampwidth(2)
            file.setframerate(rate)
            file.writeframes(b"\0\0" * round(seconds * rate))
        return data.getvalue()

    def test_bundled_recipes_and_cli(self):
        for path in video.RECIPES.glob("*.json"):
            recipe = video.load_recipe(path)
            self.assertEqual(recipe["version"], 1)
            video.main(["validate", "--recipe", str(path)])

    def test_schema_rejects_unknown_and_invalid_fields(self):
        changes = [
            ("version", 2), ("ticks", 14801), ("warmup_ticks", 14800),
            ("duration", float("nan")), ("trim_start", 999),
            ("actions", "../escape.txt"), ("sample_telemetry", "yes"),
            ("unknown", 1), ("narration", []),
            ("radio", {"screen": [0, 0, 1, 1]}),
        ]
        for key, value in changes:
            with self.subTest(key=key):
                recipe = copy.deepcopy(self.recipe)
                recipe[key] = value
                with self.assertRaises(ValueError):
                    self.validate(recipe)
        recipe = copy.deepcopy(self.recipe)
        recipe["narration"][1]["start"] = 0
        with self.assertRaises(ValueError):
            self.validate(recipe)
        recipe["narration"][1]["start"] = 10
        recipe["narration"][1]["legacy_cache"] = "../key.json"
        with self.assertRaises(ValueError):
            self.validate(recipe)

    def test_action_validation(self):
        path = self.directory / "actions.txt"
        for text in ("10 2 2 1\n", "10 2 2 0\n", "10 480 2 1\n12 480 2 0\n",
                     "12 2 2 1\n10 2 2 0\n", "10 -2 0 1\n11 2 2 1\n12 2 2 0\n"):
            path.write_text(text)
            with self.assertRaises(ValueError):
                video.read_actions(path, 20)
        path.write_text("10 2 2 1\n11 3 3 1\n12 3 3 0\n")
        self.assertEqual(len(video.read_actions(path, 20)), 3)

    def test_gesture_timing_drag_and_return(self):
        actions = [[1200, 10, 20, 1], [1210, 20, 30, 1], [1220, 20, 30, 0],
                   [1300, -2, 0, 1], [1320, -2, 0, 0]]
        gestures = video.gestures(self.recipe, actions)
        self.assertAlmostEqual(gestures[0][0], 0)
        self.assertAlmostEqual(gestures[0][1], .2)
        self.assertEqual(len(gestures[0][2]), 2)
        self.assertAlmostEqual(gestures[1][0], 1)
        self.assertAlmostEqual(gestures[1][1], 1.2)

    def test_touch_acceptance_ignores_hidden_and_key_input(self):
        recipe = dict(self.recipe, warmup_ticks=300, trim_start=1)
        actions = [[100, 5, 5, 1], [120, 5, 5, 0], [500, 5, 5, 1], [510, 6, 6, 1],
                   [520, 6, 6, 0], [600, -2, 0, 1], [620, -2, 0, 0], [700, 5, 5, 1], [720, 5, 5, 0]]
        self.assertEqual(video.accepted_touches(recipe, actions, "5010ms: TE_PRESSED\n"), [700])
        log = "5010ms: TE_PRESSED\n7140ms: TE_PRESSED\n"
        self.assertEqual(video.accepted_touches(recipe, actions, log), [])

    def test_empty_dashboard_priming_is_not_rendered(self):
        path = video.RECIPES / "create-empty-dashboard.json"
        recipe = video.load_recipe(path)
        actions = video.read_actions(path.parent / recipe["actions"], recipe["ticks"])
        primes = [a for a in actions if a[0] < recipe["warmup_ticks"]]
        self.assertTrue(primes)
        visible = video.gestures(recipe, actions)
        self.assertEqual(len(visible), len(video.gestures(recipe, actions[len(primes):])))
        self.assertIn([4500, 220, 85, 1], actions)
        self.assertNotIn("manual", json.dumps(recipe["provenance"]).lower())

    def test_frame_export_and_contact_sheet(self):
        raw = self.directory / "frames.rgb565"
        raw.write_bytes(b"\0" * video.FRAME_BYTES * 3)
        images = video.frames(raw, self.directory, [0, .05], trim_start=.05)
        self.assertEqual([image.name for image in images], ["frame-0000.00s.png", "frame-0000.05s.png"])
        with self.assertRaises(ValueError):
            video.frames(raw, self.directory, [1])
        try:
            video.ffmpeg()
        except ImportError:
            self.skipTest("Run make video-setup for FFmpeg smoke tests")
        self.assertTrue(video.contact_sheet(images, self.directory / "sheet.png").is_file())

    def test_adaptive_luminance(self):
        self.assertAlmostEqual(video.luminance(b"\0" * video.FRAME_BYTES, 240, 140), 0)
        self.assertAlmostEqual(video.luminance(b"\xff" * video.FRAME_BYTES, 240, 140), 1)

    def test_cache_identity_and_offline_import(self):
        clip = self.recipe["narration"][0]
        other = dict(clip, rate=10)
        cache = self.directory / "cache"
        self.assertNotEqual(video.cache_path(cache, clip), video.cache_path(cache, other))
        self.assertEqual(video.cache_path(cache, clip), video.cache_path(cache, dict(clip, start=2)))
        source = self.directory / "legacy"
        source.mkdir()
        (source / clip["legacy_cache"]).write_bytes(self.wav())
        recipe = dict(self.recipe, narration=[clip])
        with patch("video.urllib.request.urlopen", side_effect=AssertionError("Network forbidden")):
            imported = video.speech(recipe, cache, source=source)
            self.assertEqual(video.speech(recipe, cache), imported)
            missing = dict(recipe, narration=[other])
            with self.assertRaises(ValueError):
                video.speech(missing, cache)

    def test_rejects_truncated_long_or_wrong_format_speech(self):
        clip = self.recipe["narration"][0]
        for data in (self.wav(11), self.wav(rate=24000), self.wav()[:-4]):
            with self.assertRaises(ValueError):
                video.check_speech(data, clip)

    def test_online_uses_environment_and_xml_escaping(self):
        clip = dict(self.recipe["narration"][0], text="Speed < 10 & rising")
        recipe = dict(self.recipe, narration=[clip])
        with patch.dict("os.environ", {"AZURE_SPEECH_REGION": "westus2", "AZURE_SPEECH_KEY": "test-only"}), \
                patch("video.urllib.request.urlopen") as request:
            request.return_value.__enter__.return_value.read.return_value = self.wav()
            clips = video.speech(recipe, self.directory / "cache", online=True)
            sent = request.call_args[0][0]
            self.assertIn(b"Speed &lt; 10 &amp; rising", sent.data)
            self.assertEqual(sent.headers["Ocp-apim-subscription-key"], "test-only")
            self.assertEqual(len(clips), 1)
            for file in (self.directory / "cache").iterdir():
                self.assertNotIn(b"test-only", file.read_bytes())

    def test_sd_preparation_keeps_production_panels_untouched(self):
        original = video.ROOT / "src/WIDGETS/AeroGrid"
        sd = video.prepare(self.recipe, self.directory)
        widget = sd / "WIDGETS/AeroGrid"
        for panel in (original / "panels").glob("*.lua"):
            self.assertEqual(panel.read_bytes(), (widget / "panels" / panel.name).read_bytes())
        self.assertIn("video-inputs.lua", (widget / "lib/dashboard_loader.lua").read_text())
        self.assertNotIn("video-inputs.lua", (original / "lib/dashboard_loader.lua").read_text())
        self.assertNotIn("captureSceneOpened", (widget / "main.lua").read_text())
        self.assertFalse((sd / "capture-ready.txt").exists())
        with self.assertRaises(ValueError):
            video.prepare(self.recipe, self.directory)

    def test_offline_render_screen_and_radio(self):
        try:
            video.ffmpeg()
        except ImportError:
            self.skipTest("Run make video-setup for FFmpeg smoke tests")
        recipe = copy.deepcopy(self.recipe)
        recipe["trim_start"] = 0
        recipe["radio"].update(crop=[64, 64, 0, 0], canvas=[64, 64],
                               screen=[8, 8, 48, 28], return_button=[3, 50])
        recipe["actions"] = "test-actions.txt"
        path = self.directory / "recipe.json"
        path.write_text(json.dumps(recipe))
        (self.directory / recipe["actions"]).write_text(
            "300 200 140 1\n305 220 140 1\n310 220 140 0\n315 -2 0 1\n320 -2 0 0\n")
        raw = self.directory / "frames.rgb565"
        raw.write_bytes(b"\xff\xff" * (480 * 272 * 4))
        photo = self.directory / "photo.png"
        video.png_rgba(photo, 64, 64, b"\xc8\xc8\xc8\xff" * (64 * 64))
        with patch("video.urllib.request.urlopen", side_effect=AssertionError("Network forbidden")):
            for image in (None, photo):
                video.render(recipe, path, self.directory, raw, image,
                             self.directory / "missing-cache", True, .2)
                self.assertTrue((self.directory / f"{recipe['id']}.mp4").is_file())
                report = json.loads((self.directory / "render-provenance.json").read_text())
                self.assertIsNone(report["voice"])
                self.assertEqual(report["duration"], .2)
            clip = recipe["narration"][0]
            cache = self.directory / "cache"
            cache.mkdir()
            video.cache_path(cache, clip).write_bytes(self.wav())
            recipe["narration"] = [clip]
            video.render(recipe, path, self.directory, raw, photo, cache, False, .2)
            report = json.loads((self.directory / "render-provenance.json").read_text())
            self.assertEqual(report["voice"], video.VOICE)


if __name__ == "__main__":
    unittest.main()

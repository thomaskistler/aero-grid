# SPDX-License-Identifier: GPL-2.0-only
import importlib.util
from pathlib import Path
import re
import struct
import unittest
import wave


ROOT = Path(__file__).resolve().parents[1]
FIXTURE = ROOT / "tests/fixtures/sdcard"
REGISTRY = (
    "Empty", "Default", "Diagnostics", "review-rx-battery",
    "review-cell-sources", "review-flight-mode", "review-flight-timer",
    "review-link-status", "review-metric", "review-model-identity",
    "review-navigation", "review-state", "review-trim-panel",
    "review-tx-battery", "services", "services2", "sim", "sim2", "states",
    "review-flight-counter", "Palette", "review-output", "review-chart",
)
EXPECTED = (
    ("AG Overview", ("Default", "sim", "sim2")),
    ("AG Flight", ("review-model-identity", "review-flight-mode",
                   "review-flight-timer", "review-flight-counter", "review-chart")),
    ("AG Power-Link", ("review-rx-battery", "review-cell-sources",
                       "review-tx-battery", "review-link-status", "review-metric")),
    ("AG Navigation", ("review-navigation",)),
    ("AG Controls", ("review-output", "review-trim-panel")),
    ("AG System", ("Diagnostics", "services", "services2", "review-state",
                   "states", "Palette", "Empty")),
)


class SimulatorFixtureTests(unittest.TestCase):
    def test_registry_indices_are_unchanged(self):
        self.assertEqual(
            tuple((FIXTURE / "AEROGRID/layout-registry.txt").read_text().splitlines()),
            REGISTRY,
        )
        for name in REGISTRY:
            with self.subTest(layout=name):
                self.assertTrue(any((directory / f"{name}.yaml").is_file() for directory in (
                    ROOT / "src/WIDGETS/AeroGrid/layouts",
                    ROOT / "tests/fixtures/layouts/development",
                )))

    def test_exact_category_screen_order_and_complete_coverage(self):
        models = FIXTURE / "MODELS"
        self.assertEqual({path.name for path in models.glob("model*.yml")},
                         {f"model{number}.yml" for number in range(1, 7)})
        seen = []
        labels = (models / "labels.yml").read_text()
        self.assertIn("\nSort: 0\n", labels)
        self.assertEqual(re.findall(r"(?m)^  (model\d+\.yml):$", labels),
                         [f"model{number}.yml" for number in range(1, 7)])
        for number, (name, expected) in enumerate(EXPECTED, 1):
            with self.subTest(model=name):
                model = (models / f"model{number}.yml").read_text()
                self.assertIn(f'header:\n   name: "{name}"\n', model)
                self.assertIn(f'  model{number}.yml:\n    name: "{name}"\n', labels)
                screens = model.split("screenData:\n", 1)[1].split("topbarData:", 1)[0]
                self.assertEqual(re.findall(r"(?m)^   (\d+):$", screens),
                                 [str(index) for index in range(len(expected))])
                self.assertEqual(screens.count("LayoutId: Layout1x1AM"), len(expected))
                self.assertEqual(screens.count("widgetName: AeroGrid"), len(expected))
                values = [int(value) for value in
                          re.findall(r"unsignedValue: (\d+)", screens)]
                self.assertEqual(values[1::2], [1] * len(expected))
                actual = tuple(REGISTRY[position - 1] for position in values[::2])
                self.assertEqual(actual, expected)
                self.assertIn("view: 0\n", model)
                seen.extend(actual)
        self.assertCountEqual(seen, REGISTRY)
        radio = (FIXTURE / "RADIO/radio.yml").read_text()
        self.assertIn('currModelFilename: "model1.yml"', radio)

    def test_all_models_share_setup_and_telemetry(self):
        common = None
        for number in range(1, 7):
            model = (FIXTURE / f"MODELS/model{number}.yml").read_text()
            prefix, rest = model.split("screenData:\n", 1)
            if number == 2:
                prefix = prefix.split("logicalSw:\n", 1)[0]
            suffix = rest.split("topbarData:", 1)[1]
            setup = re.sub(r'(?m)^   name: "[^"]*"$', '   name: "shared"',
                           prefix, count=1) + "topbarData:" + suffix
            if common is None:
                common = setup
            self.assertEqual(setup, common, f"model{number} setup differs")
        self.assertIn('name: "Glide"', common)
        self.assertIn('name: "Up"', common)
        self.assertIn('value: -754', common)
        self.assertIn('value: 64', common)
        self.assertIn('label: "GPS"', common)
        self.assertIn('label: "Sats"', common)

    def test_checked_in_models_match_generator(self):
        spec = importlib.util.spec_from_file_location(
            "simulator_models", ROOT / "tools/generate-simulator-models.py")
        generator = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(generator)
        for path, content in generator.generated_files().items():
            with self.subTest(path=path.name):
                data = content.encode() if isinstance(content, str) else content
                self.assertEqual(path.read_bytes(), data)

    def test_flight_model_preserves_requested_settings(self):
        settings = FIXTURE / "AEROGRID/models"
        self.assertEqual({path.name for path in settings.glob("*.yaml")},
                         {"model2.yml".encode().hex() + ".yaml"})
        document = (settings / ("model2.yml".encode().hex() + ".yaml")).read_text()
        self.assertIn('modelFilename: "model2.yml"\n', document)
        self.assertIn('armed: "SFv"\n', document)
        self.assertIn("  minFlightDuration: 10\n", document)
        self.assertIn("  smartDetection: true\n", document)
        self.assertIn('  flightSwitch: "L01"\n', document)

    def test_only_flight_model_has_dedicated_sticky_and_one_shot_announcements(self):
        for number in range(1, 7):
            model = (FIXTURE / f"MODELS/model{number}.yml").read_text()
            if number != 2:
                self.assertNotIn("logicalSw:", model)
                self.assertNotIn("customFn:", model)
                continue
            switches = model.split("logicalSw:\n", 1)[1].split("customFn:", 1)[0]
            self.assertEqual(re.findall(r"(?m)^   (\d+):$", switches), ["0"])
            self.assertIn("func: FUNC_STICKY\n", switches)
            self.assertIn("def: NONE,NONE\n", switches)
            for key in ("delay", "duration", "lsPersist", "lsState"):
                self.assertIn(f"{key}: 0\n", switches)
            self.assertIn("andsw: NONE\n", switches)
            functions = model.split("customFn:\n", 1)[1].split("screenData:", 1)[0]
            self.assertEqual(re.findall(r"(?m)^   (\d+):$", functions), ["0", "1"])
            self.assertIn('swtch: "L1"\n      func: PLAY_TRACK\n'
                          '      def: agstart,1,!1x\n', functions)
            self.assertIn('swtch: "!L1"\n      func: PLAY_TRACK\n'
                          '      def: agend,1,!1x\n', functions)

    def test_announcement_audio_contains_exact_beep_counts(self):
        for name, count in (("agstart", 3), ("agend", 4)):
            with self.subTest(track=name):
                with wave.open(str(FIXTURE / "SOUNDS/en" / f"{name}.wav")) as audio:
                    self.assertEqual(audio.getnchannels(), 1)
                    self.assertEqual(audio.getsampwidth(), 2)
                    self.assertEqual(audio.getframerate(), 32000)
                    self.assertEqual(audio.getcomptype(), "NONE")
                    self.assertEqual(audio.getnframes(), count * 2560)
                    frames = audio.readframes(audio.getnframes())
                samples = struct.unpack(f"<{count * 2560}h", frames)
                for index in range(count):
                    tone = samples[index * 2560:index * 2560 + 1920]
                    pause = samples[index * 2560 + 1920:(index + 1) * 2560]
                    self.assertGreater(max(tone), 8000)
                    self.assertLess(min(tone), -8000)
                    crossings = sum(a <= 0 < b for a, b in zip(tone, tone[1:]))
                    self.assertEqual(crossings, 135)  # 2250 Hz for 60 ms.
                    self.assertFalse(any(pause))

    def test_altitude_review_sources_match_simulator(self):
        model = (FIXTURE / "MODELS/model1.yml").read_text()
        self.assertIn('label: "GAlt"', model)
        layouts = ROOT / "tests/fixtures/layouts/development"
        for path in layouts.glob("*.yaml"):
            with self.subTest(layout=path.name):
                self.assertNotRegex(path.read_text(), r"\bsource:\s*Alt(?:\s|$)")


if __name__ == "__main__":
    unittest.main()

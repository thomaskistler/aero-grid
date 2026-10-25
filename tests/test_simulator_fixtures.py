# SPDX-License-Identifier: GPL-2.0-only
import importlib.util
from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]
FIXTURE = ROOT / "tests/fixtures/sdcard"
REGISTRY = (
    "Empty", "Default", "Diagnostics", "review-rx-battery",
    "review-cell-sources", "review-flight-mode", "review-flight-timer",
    "review-link-status", "review-metric", "review-model-identity",
    "review-navigation", "review-state", "review-trim-panel",
    "review-tx-battery", "services", "services2", "sim", "sim2", "states",
    "review-flight-counter", "Palette", "review-output", "review-map",
)
EXPECTED = (
    ("AG Overview", ("Default", "sim", "sim2")),
    ("AG Flight", ("review-model-identity", "review-flight-mode",
                   "review-flight-timer", "review-flight-counter")),
    ("AG Power-Link", ("review-rx-battery", "review-cell-sources",
                       "review-tx-battery", "review-link-status", "review-metric")),
    ("AG Navigation", ("review-navigation", "review-map")),
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
                self.assertEqual(path.read_bytes(), content.encode())

    def test_map_sample_preserves_sources_and_arm_switch(self):
        layout = (ROOT / "tests/fixtures/layouts/development/review-map.yaml").read_text()
        self.assertIn("      source: GPS\n", layout)
        self.assertIn("      armSwitch: SFv\n", layout)
        self.assertIn("      satelliteSource: Sats\n", layout)


if __name__ == "__main__":
    unittest.main()

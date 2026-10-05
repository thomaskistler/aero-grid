# SPDX-License-Identifier: GPL-2.0-only
import copy
from pathlib import Path
import tempfile
import unittest

import yaml
from capture_recipes import (COMPONENTS, RECIPE_DIR, configure_model, config_yaml,
                            fixture_inputs, load_recipe, readiness)


class CaptureRecipeTests(unittest.TestCase):
    def load(self, recipe):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "recipe.yaml"
            path.write_text(yaml.safe_dump(recipe))
            return load_recipe(path)

    def test_shipped_recipes(self):
        self.assertEqual({path.stem for path in RECIPE_DIR.glob("*.yaml")}, set(COMPONENTS))
        for path in RECIPE_DIR.glob("*.yaml"):
            recipe = load_recipe(path)
            self.assertEqual(len(recipe["panels"]), 3)
            self.assertIn("feed", readiness(recipe))

    def test_nested_metrics_config(self):
        recipe = load_recipe(RECIPE_DIR / "metric.yaml")
        self.assertEqual(yaml.safe_load(config_yaml(recipe["config"])), recipe["config"])
        recipe["config"]["metrics"][0]["source"] = "Missing"
        with self.assertRaisesRegex(ValueError, "Missing sample"):
            self.load(recipe)

    def test_synthetic_samples_propagate(self):
        for component in ("metric", "cell-battery", "link-status", "navigation"):
            recipe = load_recipe(RECIPE_DIR / f"{component}.yaml")
            inputs = fixture_inputs(recipe)
            for name in recipe["sample"]["sources"]:
                self.assertIn(name, inputs)
                self.assertIn(name, readiness(recipe))
            self.assertIn("getFieldInfo", inputs)
            self.assertEqual(configure_model("unchanged\n", recipe), "unchanged\n")
        recipe = load_recipe(RECIPE_DIR / "tx-battery.yaml")
        recipe["sample"]["voltage"] = 7.6
        self.assertIn("return 7.6", fixture_inputs(self.load(recipe)))
        self.assertIn("feed.value ~= 7.6", readiness(recipe))
        for component in ("flight-timer", "flight-mode", "model-identity", "trim-panel"):
            self.assertIsNone(fixture_inputs(load_recipe(RECIPE_DIR / f"{component}.yaml")))

    def test_model_and_flight_mode_setup(self):
        identity = load_recipe(RECIPE_DIR / "model-identity.yaml")
        model = yaml.safe_load(configure_model(
            'header:\n   name: Old\n   bitmap: old.png\nother: 42\n', identity))
        self.assertEqual(model["header"]["name"], "Crack Yak")
        self.assertEqual(model["header"]["bitmap"], "crackyak.png")
        self.assertEqual(model["other"], 42)
        mode = load_recipe(RECIPE_DIR / "flight-mode.yaml")
        model = yaml.safe_load(configure_model("", mode))
        self.assertEqual(model["flightModeData"][0]["name"], "ACRO")

    def test_invalid_synthetic_samples(self):
        cases = [
            ("metric", lambda r: r["sample"]["sources"]["GAlt"].update(value=float("nan"))),
            ("metric", lambda r: r["sample"]["sources"]["GAlt"].update(value=True)),
            ("metric", lambda r: r["sample"]["sources"]["GAlt"].update(precision=4)),
            ("metric", lambda r: r["sample"].update(rssi=0)),
            ("cell-battery", lambda r: r["sample"]["sources"]["Cels"].update(value=[])),
            ("cell-battery", lambda r: r["sample"]["sources"]["Cels"].update(unit=1)),
            ("navigation", lambda r: r["sample"]["sources"]["GPS"]["value"].update(lat=91)),
            ("navigation", lambda r: r["sample"]["sources"]["GPS"]["value"].update(
                **{"pilot-lat": 0, "pilot-lon": 0})),
            ("tx-battery", lambda r: r["config"].update(packFull=6.4)),
            ("flight-mode", lambda r: r["sample"].update(name="too long for firmware")),
        ]
        for component, mutate in cases:
            with self.subTest(component=component):
                recipe = load_recipe(RECIPE_DIR / f"{component}.yaml")
                mutate(recipe)
                with self.assertRaises(ValueError):
                    self.load(recipe)

    def test_custom_timer_values_propagate(self):
        recipe = load_recipe(RECIPE_DIR / "flight-timer.yaml")
        recipe["sample"] = {"name": 'Test "A"', "start_seconds": 600, "remaining_seconds": 123}
        recipe["config"].update(timer=1, label="Custom", accent="cyan")
        recipe = self.load(recipe)
        model = configure_model("header:\n   name: Test\n", recipe)
        self.assertIn("   1:\n", model)
        self.assertIn("value: 123", model)
        self.assertIn("feed.value ~= 123", readiness(recipe))
        self.assertIn('label: "Custom"', config_yaml(recipe["config"]))
        self.assertEqual(yaml.safe_load(model)["timers"][1]["name"], 'Test "A"')

    def test_replacing_existing_timers_keeps_following_fields(self):
        recipe = load_recipe(RECIPE_DIR / "flight-timer.yaml")
        model = configure_model("timers:\n   0:\n      value: 9\nother: 42\n", recipe)
        self.assertIn("other: 42", model)
        self.assertNotIn("value: 9", model)

    def test_trim_values_propagate(self):
        recipe = load_recipe(RECIPE_DIR / "trim-panel.yaml")
        recipe["sample"]["aileron"] = 5
        recipe = self.load(recipe)
        self.assertIn("value: 5", configure_model("", recipe))
        self.assertIn("{ 5, -26, 0 }", readiness(recipe))

    def test_invalid_recipes(self):
        base = load_recipe(RECIPE_DIR / "flight-timer.yaml")
        mutations = [
            lambda r: r.update(unknown=True),
            lambda r: r["sample"].update(remaining_seconds=True),
            lambda r: r["sample"].update(name="too long for timer"),
            lambda r: r["config"].update(timer=3),
            lambda r: r["border"].update(rgb=[0, 0, 256]),
            lambda r: r["panels"]["2x2"].update(row=3),
            lambda r: r["panels"]["2x2"].update(row=0),
            lambda r: r["panels"]["1x2"].update(colSpan=2),
            lambda r: r.update(component="unknown"),
            lambda r: r.update(hide_bottom_bar="true"),
            lambda r: r.update(brighten_supporting_text="true"),
        ]
        for mutation in mutations:
            recipe = copy.deepcopy(base)
            mutation(recipe)
            with self.assertRaises(ValueError):
                self.load(recipe)

    def test_duplicate_keys_and_unsafe_yaml_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "invalid.yaml"
            for text in ("version: 1\nversion: 2\n", "!!python/object:example {}\n"):
                path.write_text(text)
                with self.assertRaises(ValueError):
                    load_recipe(path)


if __name__ == "__main__":
    unittest.main()

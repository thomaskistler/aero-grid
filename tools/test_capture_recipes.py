# SPDX-License-Identifier: GPL-2.0-only
import copy
import importlib.util
from pathlib import Path
import tempfile
import unittest

import yaml
from capture_recipes import (PANELS, RECIPE_DIR, configure_model, config_yaml,
                            fixture_inputs, load_recipe, readiness)


class CaptureRecipeTests(unittest.TestCase):
    def test_modern_light_capture_uses_native_choice_two(self):
        spec = importlib.util.spec_from_file_location("capture_panels", Path(__file__).with_name("capture-panels.py"))
        capture = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(capture)
        recipe = load_recipe(RECIPE_DIR / "metric.yaml")
        recipe["theme"] = "modern-light"
        recipe = self.load(recipe)
        with tempfile.TemporaryDirectory() as directory:
            sd = Path(directory) / "sdcard"
            capture.prepare(sd, recipe)
            layout = yaml.safe_load((sd / "WIDGETS/AeroGrid/layouts/capture-panels.yaml").read_text())
            self.assertNotIn("theme", layout)
            model = yaml.safe_load((sd / "MODELS/model1.yml").read_text())
            options = model["screenData"][0]["layoutData"]["zones"][0]["widgetData"]["options"]
            self.assertEqual(options[1]["value"]["unsignedValue"], 2)

    def test_old_recipe_field_is_rejected(self):
        recipe = load_recipe(RECIPE_DIR / "flight-timer.yaml")
        recipe["component"] = recipe.pop("panel")
        with self.assertRaises(ValueError):
            self.load(recipe)

    def test_prepared_captures_use_panel_contract(self):
        path = Path(__file__).with_name("capture-panels.py")
        spec = importlib.util.spec_from_file_location("capture_panels", path)
        capture = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(capture)
        for recipe_path in RECIPE_DIR.glob("*.yaml"):
            with self.subTest(panel=recipe_path.stem), tempfile.TemporaryDirectory() as directory:
                recipe = load_recipe(recipe_path)
                sd = Path(directory) / "sdcard"
                capture.prepare(sd, recipe, recipe_path)
                widget = sd / "WIDGETS/AeroGrid"
                layout = yaml.safe_load((widget / "layouts/capture-panels.yaml").read_text())
                self.assertEqual(len(layout["panels"]), len(recipe["panels"]))
                self.assertTrue(all(entry["type"] == recipe["panel"] for entry in layout["panels"]))
                self.assertTrue((widget / "panels" / f"{recipe['panel']}.lua").is_file())
                self.assertTrue((widget / "lib/panel_host.lua").is_file())
                self.assertIn("ipairs(context.panels)", (widget / "main.lua").read_text())
                radio = yaml.safe_load((sd / "RADIO/radio.yml").read_text())
                self.assertEqual(radio["currModelFilename"], "model1.yml")
                model = yaml.safe_load((sd / "MODELS/model1.yml").read_text())
                self.assertEqual(len(model["screenData"]), 1)
                names = (sd / "AEROGRID/registry.txt").read_text().splitlines()
                position = model["screenData"][0]["layoutData"]["zones"][0]["widgetData"]["options"][0]["value"]["unsignedValue"]
                self.assertEqual(names[position - 1], "capture-panels")

    def test_editor_preparation_uses_isolated_default_screen(self):
        path = Path(__file__).with_name("capture-editor.py")
        spec = importlib.util.spec_from_file_location("capture_editor", path)
        capture = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(capture)
        for scene in capture.SCENES + tuple(capture.SETUP_SCENES):
            with self.subTest(scene=scene), tempfile.TemporaryDirectory() as directory:
                sd = Path(directory) / "sdcard"
                capture.prepare(sd, scene)
                radio = yaml.safe_load((sd / "RADIO/radio.yml").read_text())
                self.assertEqual(radio["currModelFilename"], "model1.yml")
                model = yaml.safe_load((sd / "MODELS/model1.yml").read_text())
                self.assertEqual(list(model["screenData"]), [0])
                screen = model["screenData"][0]
                self.assertEqual(screen["LayoutId"], "Layout1x1AM")
                options = screen["layoutData"]["zones"][0]["widgetData"]["options"]
                names = (sd / "AEROGRID/registry.txt").read_text().splitlines()
                self.assertEqual(names[options[0]["value"]["unsignedValue"] - 1], "Default")
                self.assertEqual(options[1]["value"]["unsignedValue"], 1)
                self.assertFalse((sd / "MODELS/model4.yml").exists())

    def load(self, recipe):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "recipe.yaml"
            path.write_text(yaml.safe_dump(recipe))
            return load_recipe(path)

    def test_shipped_recipes(self):
        self.assertEqual({path.stem for path in RECIPE_DIR.glob("*.yaml")}, set(PANELS))
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

    def test_state_switch_samples(self):
        recipe = load_recipe(RECIPE_DIR / "state.yaml")
        self.assertEqual(yaml.safe_load(config_yaml(recipe["config"])), recipe["config"])
        self.assertIn('entry.instance.text ~= "ARMED"', readiness(recipe))
        self.assertIn("feed.fresh", readiness(recipe))
        inputs = fixture_inputs(recipe)
        self.assertIn("return switch.id", inputs)
        self.assertIn("getSwitchValue", inputs)
        self.assertNotIn("unit =", inputs)
        for mutate in (
            lambda r: r["sample"]["switches"].update(sf="invalid"),
            lambda r: r["sample"]["switches"].pop("sf"),
            lambda r: r["config"]["entries"][0]["states"][0].update(text=True),
            lambda r: r["config"]["entries"][0]["states"][0].update(background="red"),
            lambda r: r["config"]["entries"][0].update(states=[]),
            lambda r: r["config"].update(entries=[]),
        ):
            invalid = copy.deepcopy(recipe)
            mutate(invalid)
            with self.assertRaises(ValueError):
                self.load(invalid)

    def test_state_logical_condition_priority(self):
        recipe = load_recipe(RECIPE_DIR / "state.yaml")
        recipe["sample"]["switches"]["L01"] = True
        recipe["config"]["entries"][0]["states"][0]["switch"] = "L01"
        recipe = self.load(recipe)
        self.assertIn('entry.instance.text ~= "DISARMED"', readiness(recipe))
        self.assertIn('["L01"]', fixture_inputs(recipe))
        recipe["sample"]["switches"]["L01"] = False
        self.assertIn('entry.instance.text ~= "ARMED"', readiness(self.load(recipe)))
        recipe["sample"]["switches"]["L01"] = 1
        with self.assertRaises(ValueError):
            self.load(recipe)

    def test_flight_counter_samples(self):
        recipe = load_recipe(RECIPE_DIR / "flight-counter.yaml")
        self.assertIn("model.setGlobalVariable(8, 0, 39)", fixture_inputs(recipe))
        self.assertIn("feed.raw ~= 42", readiness(recipe))
        self.assertIn('entry.instance.badgeText ~= "IN-FLIGHT"', readiness(recipe))
        recipe["sample"]["count"] = 72
        self.assertIn("model.setGlobalVariable(8, 0, 69)", fixture_inputs(self.load(recipe)))
        for mutate in (
            lambda r: r["sample"].update(count=1000),
            lambda r: r["sample"].update(count=2),
            lambda r: r["sample"].update(rssi=0),
            lambda r: r["config"].update(history=True),
            lambda r: r["config"].update(motorReversed=True),
            lambda r: r["config"].update(minFlightDuration=30),
        ):
            invalid = copy.deepcopy(recipe)
            mutate(invalid)
            with self.assertRaises(ValueError):
                self.load(invalid)

    def test_synthetic_samples_propagate(self):
        for panel in ("metric", "cell-battery", "link-status", "navigation"):
            recipe = load_recipe(RECIPE_DIR / f"{panel}.yaml")
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
        for panel in ("flight-timer", "flight-mode", "model-identity", "trim-panel"):
            self.assertIsNone(fixture_inputs(load_recipe(RECIPE_DIR / f"{panel}.yaml")))

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
        for panel, mutate in cases:
            with self.subTest(panel=panel):
                recipe = load_recipe(RECIPE_DIR / f"{panel}.yaml")
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
            lambda r: r.update(panel="unknown"),
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

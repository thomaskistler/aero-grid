# SPDX-License-Identifier: GPL-2.0-only
from pathlib import Path
import tempfile
import unittest

from tool_test_support import load_tool

capture = load_tool("capture_editor", "capture-editor.py")


class ThemeCaptureTests(unittest.TestCase):
    def test_dashboard_uses_production_layout_and_isolated_samples(self):
        with tempfile.TemporaryDirectory() as directory:
            sd = Path(directory) / "sdcard"
            capture.prepare(sd, "dashboard")
            widget = sd / "WIDGETS/AeroGrid"
            self.assertEqual(
                (widget / "layouts/Default.yaml").read_bytes(),
                (capture.ROOT / "src/WIDGETS/AeroGrid/layouts/Default.yaml").read_bytes(),
            )
            self.assertEqual(
                (widget / "capture-inputs.lua").read_text(), capture.DASHBOARD_INPUTS,
            )
            self.assertEqual(
                (sd / "IMAGES/crackyak.png").read_bytes(),
                (capture.ROOT / "tools/capture-assets/crackyak.png").read_bytes(),
            )
            source = (widget / "main.lua").read_text()
            self.assertIn("production Default dashboard and sample readings verified", source)
            self.assertIn('["flight-clock"] = "5:47"', source)
            self.assertIn('["flight-count"] = "42"', source)
            self.assertIn('entry.placement.id == "outputs"', source)
            self.assertIn("if #context.panels ~= 7 then return end", source)
            self.assertNotIn('local scene = "', source)
            loader = (widget / "lib/dashboard_loader.lua").read_text()
            self.assertIn('loadScript("/WIDGETS/AeroGrid/capture-inputs.lua")', loader)
            self.assertNotIn("context.theme.rgb.textFaint =", loader)
            model = (sd / "MODELS/model1.yml").read_text()
            self.assertIn('name: "Crack Yak"', model)
            self.assertIn("value: 347", model)
            self.assertIn("start: 600", model)

    def test_theme_scenes_use_production_showcase(self):
        for scene in capture.THEME_SCENES:
            with self.subTest(scene=scene), tempfile.TemporaryDirectory() as directory:
                sd = Path(directory) / "sdcard"
                capture.prepare(sd, scene)
                widget = sd / "WIDGETS/AeroGrid"
                layout = (widget / "layouts/Default.yaml").read_text()
                source = (widget / "main.lua").read_text()
                self.assertIn("type: theme-showcase", layout)
                self.assertIn("production theme showcase ready", source)
                self.assertIn(f'context.theme.mode == "{scene.removeprefix("theme-")}"', source)
                self.assertNotIn('local scene = "', source)
                model = (sd / "MODELS/model1.yml").read_text()
                theme_option = model.split("                     1:\n", 1)[1]
                position = {"theme-modern-light": 2, "theme-custom": 3}.get(scene, 1)
                self.assertIn(f"unsignedValue: {position}", theme_option)
                if scene == "theme-custom":
                    themes = (sd / "AEROGRID/themes/custom.yml").read_text()
                    self.assertIn("name: custom", themes)
                    self.assertIn("canvas: 0x101820", themes)
                    self.assertEqual(
                        (sd / "AEROGRID/theme-registry.txt").read_text(),
                        "modern-dark\nmodern-light\ncustom\n",
                    )
                else:
                    self.assertNotIn("\ntheme:\n", layout)


if __name__ == "__main__":
    unittest.main()

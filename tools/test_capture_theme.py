# SPDX-License-Identifier: GPL-2.0-only
import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("capture_editor", Path(__file__).with_name("capture-editor.py"))
capture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(capture)


class ThemeCaptureTests(unittest.TestCase):
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
                    self.assertIn("unsignedValue: 3", theme_option)
                else:
                    self.assertNotIn("\ntheme:\n", layout)


if __name__ == "__main__":
    unittest.main()

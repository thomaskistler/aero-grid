# SPDX-License-Identifier: GPL-2.0-only
"""Verify exact native menu icon alpha and inverse selection artwork offline."""
import hashlib
import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("menu_tiles", ROOT / "tools/generate-menu-tiles.py")
tiles = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tiles)
spec = importlib.util.spec_from_file_location("menu_capture", ROOT / "tools/capture-editor.py")
capture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(capture)


class MenuTilesTests(unittest.TestCase):
    def test_title_tab_dimensions_and_colors(self):
        for size in tiles.DISPLAYS.values():
            rows = tiles.png.read_png(ROOT / f"src/WIDGETS/AeroGrid/assets/menu-title-{size}.png")
            self.assertEqual(len(rows), int(25 * size / 45 + 0.5))
            self.assertEqual(len(rows[0]), int(122 * size / 45 + 0.5))
            colors = {pixel[:3] for row in rows for pixel in row if pixel[3] == 255}
            self.assertIn((0, 0, 0), colors)
            self.assertIn((255, 255, 255), colors)
            self.assertEqual(rows[-1][0][3], 0, "title tab must taper on both sides")

    def test_native_dimensions_and_inverse_artwork(self):
        sizes = {36: 24, 45: 30, 62: 41}
        for size, dimension in sizes.items():
            for icon in tiles.ICONS:
                images = {}
                for name, foreground in (("black", 0), ("white", 255)):
                    path = ROOT / f"src/WIDGETS/AeroGrid/assets/menu-{icon}-{name}-{size}.png"
                    rows = tiles.png.read_png(path)
                    self.assertEqual(len(rows), dimension)
                    self.assertTrue(all(len(row) == dimension for row in rows))
                    self.assertTrue(all(pixel[:3] == (foreground,) * 3 for row in rows for pixel in row))
                    images[name] = bytes(pixel[3] for row in rows for pixel in row)
                self.assertEqual(images["white"], images["black"], "selection only changes foreground color")
                self.assertIn(0, images["white"])
                self.assertIn(255, images["white"])
                self.assertGreater(len(set(images["white"])), 2, "retain the native antialiased line art")

    def test_official_v212_masks_are_not_rescaled_or_replaced(self):
        # SHA256 of 255 - grayscale in the official v2.12.0 mask_menu_*.png.
        expected = {
            ("model", 36): "3eb087a537fa618ba339155ed54962ddaf9d01f049ec60ef3606e383cecf1dac",
            ("theme", 36): "bf852c5d4f1be02f69fc4010ee35d63baeba4f535a09713cba92953f030d91ad",
            ("model", 45): "1650222969f41623cbf6a5fc08e5a4e1b8cb7d57db5413c87b715fe99601cb1c",
            ("theme", 45): "5ad3e1eab025bf20e18e64f47fa87fb5a2bbf65e48d9aedd49919475562bf294",
            ("model", 62): "2c58417f8fad8867dd26e3af5b64c50eb9fc70ceeb22c6255e42cf60c00fc8fc",
            ("theme", 62): "2cde45a04134bff6b767940a71ec14af625463c608086fbddb3f7360f5350039",
        }
        self.assertEqual(len(expected), 6)
        for (icon, size), digest in expected.items():
            rows = tiles.png.read_png(ROOT / f"src/WIDGETS/AeroGrid/assets/menu-{icon}-white-{size}.png")
            alpha = bytes(pixel[3] for row in rows for pixel in row)
            self.assertEqual(hashlib.sha256(alpha).hexdigest(), digest)

    def test_frame_verification_rejects_missing_or_wrong_inverse_artwork(self):
        rows = [bytearray(480 * 3) for _ in range(272)]

        def rectangle(left, top, width, height, value):
            for y in range(top, top + height):
                rows[y][left * 3:(left + width) * 3] = bytes([value] * width * 3)

        rectangle(208, 58, 64, 10, 255)
        rectangle(134, 49, 212, 3, 255)
        rectangle(180, 53, 120, 21, 255)
        rectangle(146, 81, 88, 80, 255)
        rectangle(181, 90, 12, 12, 0)
        rectangle(281, 90, 12, 12, 255)
        self.assertEqual(capture.verify_menu_grid(rows, 1)["selected"], 1)
        rectangle(134, 49, 212, 3, 0)
        with self.assertRaisesRegex(RuntimeError, "title rule"):
            capture.verify_menu_grid(rows, 1)
        rectangle(134, 49, 212, 3, 255)
        with self.assertRaisesRegex(RuntimeError, "invert"):
            capture.verify_menu_grid(rows, 2)
        rectangle(181, 90, 12, 12, 255)
        with self.assertRaisesRegex(RuntimeError, "icon is missing"):
            capture.verify_menu_grid(rows, 1)


if __name__ == "__main__":
    unittest.main()

# SPDX-License-Identifier: GPL-2.0-only
"""Native header geometry regression tests, independent of simulator availability."""
import importlib.util
import hashlib
import re
from pathlib import Path
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / "tools" / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


icons = load("menu_icons", "generate-menu-icon.py")
capture = load("menu_capture", "capture-editor.py")


class MenuIconTests(unittest.TestCase):
    def test_exact_native_background_masks(self):
        hashes = {
            36: "6318abc1e8fd52d4925d2997fde890487611fd3724b49a5905f16ec65e1e7738",
            45: "73017f6acf9a91ea2589e205afef84b83ec9465e40eba776bd1b6fdc9294b7e2",
            62: "f47a410f20c0d3cd2ff208ac1858cfa72dd91084ff09d3aab49d18a5292ec39a",
        }
        source = (ROOT / "src/WIDGETS/AeroGrid/lib/aerogrid_menu.lua").read_text()
        for size, expected in hashes.items():
            packed = re.search(rf'\[{size}\] = "([^"]+)"', source).group(1)
            values = [int(value) for value in re.findall(r"\\(\d+)", packed)]
            self.assertEqual(len(values) % 5, 0)
            pixels = bytearray(size * size)
            for index in range(0, len(values), 5):
                x, y, width, height, alpha = values[index:index + 5]
                for row in range(y, y + height):
                    for column in range(x, x + width):
                        self.assertEqual(pixels[row * size + column], 0, "mask runs must not overlap")
                        pixels[row * size + column] = alpha
            self.assertEqual(hashlib.sha256(pixels).hexdigest(), expected)

    def test_selected_straight_grid_design(self):
        svg = ET.parse(ROOT / "src/WIDGETS/AeroGrid/assets/aerogrid.svg").getroot()
        ns = {"svg": "http://www.w3.org/2000/svg"}
        self.assertIsNone(svg.find("svg:path", ns))
        grid = svg.find("svg:g", ns)
        self.assertEqual(grid.get("fill"), "#DCEAF0")
        self.assertEqual(grid.get("clip-path"), "url(#grid-inset)")
        tiles = grid.findall("svg:rect", ns)
        self.assertEqual(len(tiles), 9)
        self.assertEqual({float(tile.get("x")) for tile in tiles}, {6, 17.5, 29})
        self.assertEqual({float(tile.get("y")) for tile in tiles}, {6, 17.5, 29})
        self.assertTrue(all(tile.get("transform") is None for tile in tiles))
        plane = svg.find("svg:image", ns)
        self.assertEqual(plane.get("x"), "4.5")
        self.assertEqual(plane.get("y"), "1")
        self.assertIsNone(plane.get("transform"))

    def test_transparent_artwork_assets_at_every_display_size(self):
        for size in (36, 45, 62):
            rows = icons.read_png(ROOT / "src/WIDGETS/AeroGrid/assets" / icons.asset_name(size))
            self.assertEqual(len(rows), size)
            self.assertTrue(all(len(row) == size for row in rows))
            self.assertEqual(rows[0][0][3], 0)
            self.assertEqual(rows[0][-1][3], 0)
            self.assertGreater(sum(pixel[3] > 0 for row in rows for pixel in row), 0)
            opaque_colors = {
                pixel[:3]
                for row in rows
                for pixel in row
                if pixel[3] == 255
            }
            self.assertIn((220, 234, 240), opaque_colors)
            self.assertTrue(any(min(pixel[:3]) >= 250 for pixel in opaque_colors))

    def test_capture_comparison_rejects_hitbox_only_parity(self):
        black = bytes(480 * 3)
        rows = [black for _ in range(272)]
        for y in range(45):
            rows[y] = bytes([255] * (45 * 3)) + black[45 * 3:]
        report = capture.verify_menu_icon_pair(rows, rows)
        self.assertEqual(report["bounds"], [0, 0, 45, 45])
        smaller = list(rows)
        smaller[0] = black
        with self.assertRaisesRegex(RuntimeError, "silhouettes differ"):
            capture.verify_menu_icon_pair(rows, smaller)


if __name__ == "__main__":
    unittest.main()

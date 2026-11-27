# SPDX-License-Identifier: GPL-2.0-only
"""Native header geometry regression tests, independent of simulator availability."""
from pathlib import Path
import unittest
import xml.etree.ElementTree as ET

from tool_test_support import load_tool

ROOT = Path(__file__).resolve().parents[1]

icons = load_tool("menu_icons", "generate-menu-icon.py")
capture = load_tool("menu_capture", "capture-editor.py")


class MenuIconTests(unittest.TestCase):
    def test_menu_uses_approved_aerogrid_emblem(self):
        svg = ET.parse(ROOT / "src/WIDGETS/AeroGrid/assets/aerogrid.svg").getroot()
        approved = ET.parse(ROOT / "docs/assets/branding/aerogrid-mark.svg").getroot()
        ns = {"svg": "http://www.w3.org/2000/svg"}
        mark = svg.find(".//*[@id='mark']")
        reference = approved.find(".//*[@id='mark']")
        self.assertEqual(mark.get("d"), reference.get("d"))
        self.assertEqual(mark.get("fill"), reference.get("fill"))
        for tag in ("image", "text", "rect"):
            self.assertEqual(svg.findall(".//svg:" + tag, ns), [])

    def test_transparent_artwork_assets_at_every_display_size(self):
        for size in (36, 45, 62):
            variants = []
            for light in (False, True):
                with self.subTest(size=size, light=light):
                    rows = icons.read_png(
                        ROOT / "src/WIDGETS/AeroGrid/assets" / icons.asset_name(size, light))
                    variants.append(rows)
                    self.assertEqual(len(rows), size)
                    self.assertTrue(all(len(row) == size for row in rows))
                    self.assertEqual(rows[0][0][3], 0)
                    self.assertEqual(rows[0][-1][3], 0)
                    self.assertGreater(sum(pixel[3] > 0 for row in rows for pixel in row), 0)
                    opaque_colors = {
                        pixel[:3] for row in rows for pixel in row if pixel[3] == 255
                    }
                    self.assertEqual(opaque_colors, {icons.green(light)})
            self.assertEqual([[pixel[3] for pixel in row] for row in variants[0]],
                             [[pixel[3] for pixel in row] for row in variants[1]])

    def test_capture_requires_square_tab_with_only_bottom_right_rounding(self):
        black = bytes(480 * 3)
        rows = [black for _ in range(272)]
        rounded = list(rows)
        for y in range(45):
            rows[y] = bytes([255] * (45 * 3)) + black[45 * 3:]
            visible = sum(x < 37 or y < 37 or (x + 0.5 - 37) ** 2 + (y + 0.5 - 37) ** 2 <= 64
                          for x in range(45))
            rounded[y] = bytes([255] * (visible * 3)) + black[visible * 3:]
        report = capture.verify_menu_icon_pair(rows, rounded)
        self.assertEqual(report["bounds"], [0, 0, 45, 45])
        self.assertEqual(report["corner_radius"], 8)
        with self.assertRaisesRegex(RuntimeError, "bottom-right"):
            capture.verify_menu_icon_pair(rows, rows)
        smaller = list(rounded)
        smaller[0] = black
        with self.assertRaisesRegex(RuntimeError, "bounds"):
            capture.verify_menu_icon_pair(rows, smaller)
        other_corner = list(rounded)
        other_corner[0] = bytes(6 * 3) + rounded[0][6 * 3:]
        with self.assertRaisesRegex(RuntimeError, "bottom-right"):
            capture.verify_menu_icon_pair(rows, other_corner)
        wider = list(rounded)
        wider[0] = bytes([255] * (46 * 3)) + black[46 * 3:]
        with self.assertRaisesRegex(RuntimeError, "bounds"):
            capture.verify_menu_icon_pair(rows, wider)
        hole = list(rounded)
        hole[0] = rounded[0][:30] + bytes(3) + rounded[0][33:]
        with self.assertRaisesRegex(RuntimeError, "bottom-right"):
            capture.verify_menu_icon_pair(rows, hole)


if __name__ == "__main__":
    unittest.main()

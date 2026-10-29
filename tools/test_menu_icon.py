# SPDX-License-Identifier: GPL-2.0-only
"""Native header geometry regression tests, independent of simulator availability."""
import hashlib
import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / "tools" / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


icons = load("menu_icons", "generate-menu-icon.py")
capture = load("menu_capture", "capture-editor.py")


class MenuIconTests(unittest.TestCase):
    def test_exact_native_mask_at_every_display_size(self):
        # SHA256 of 255 - grayscale for every pixel of the official v2.12.0
        # radio/src/bitmaps/<display>/default_theme/mask_topleft.png.
        alpha_hashes = {
            36: "6318abc1e8fd52d4925d2997fde890487611fd3724b49a5905f16ec65e1e7738",
            45: "73017f6acf9a91ea2589e205afef84b83ec9465e40eba776bd1b6fdc9294b7e2",
            62: "f47a410f20c0d3cd2ff208ac1858cfa72dd91084ff09d3aab49d18a5292ec39a",
        }
        for variant in icons.VARIANTS:
            for size, expected in alpha_hashes.items():
                rows = icons.read_png(ROOT / "src/WIDGETS/AeroGrid/assets" / icons.asset_name(variant, size))
                self.assertEqual(len(rows), size)
                self.assertTrue(all(len(row) == size for row in rows))
                self.assertEqual(hashlib.sha256(bytes(pixel[3] for row in rows for pixel in row)).hexdigest(),
                                 expected)
                self.assertEqual(rows[0][-1][3], 0, "angled corner must remain transparent")
                self.assertGreater(rows[size // 2][-1][3], 0, "native antialiased tip reaches the final column")

    def test_runtime_variants_match_generated_backgrounds(self):
        source = (ROOT / "src/WIDGETS/AeroGrid/lib/aerogrid_menu.lua").read_text()
        for variant, color in icons.VARIANTS.items():
            red, green, blue = (int(color[i:i + 2], 16) for i in (1, 3, 5))
            self.assertIn(f'{{ name = "{variant}", {red}, {green}, {blue} }}', source)
        self.assertLess(source.index('"orange"'), source.index('"violet"'))

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

# SPDX-License-Identifier: GPL-2.0-only
import importlib.util
from io import BytesIO
from pathlib import Path
import struct
import tempfile
import unittest
from PIL import Image


spec = importlib.util.spec_from_file_location(
    "map_pack", Path(__file__).with_name("generate-map-test-pack.py"))
generator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(generator)
icon_spec = importlib.util.spec_from_file_location(
    "map_icons", Path(__file__).with_name("generate-map-icons.py"))
icons = importlib.util.module_from_spec(icon_spec)
icon_spec.loader.exec_module(icons)


class MapPackTests(unittest.TestCase):
    def test_home_visible_width(self):
        sample = icons.home_marker()
        columns = [x for x in range(52) if any(
            sample(x + (sx + 0.5) / 3, y + (sy + 0.5) / 3)
            for y in range(52) for sy in range(3) for sx in range(3))]
        self.assertEqual(max(columns) - min(columns) + 1, 28)

    def test_home_reduction_preserves_pin_anchor_and_scales_styling(self):
        original = icons.styled(icons.home, 12, icons.HOME_COLOR)
        reduced = icons.home_marker()
        for y in range(52):
            for x in range(52):
                self.assertEqual(reduced(x, y),
                                 original(24 + (x - 24) / 0.85,
                                          50 + (y - 50) / 0.85))
        self.assertIsNotNone(reduced(24, 49.5))
        self.assertIsNone(reduced(24, 50.5))

    def test_home_pin_tip_matches_runtime_anchor(self):
        self.assertIsNotNone(icons.home(18, 29.8))
        self.assertIsNone(icons.home(16, 30))
        self.assertIsNone(icons.home(20, 30))
        self.assertIsNone(icons.home(18, 31))
        self.assertEqual(icons.home(18, 10), (0, 0, 0))
        self.assertEqual(icons.home(18, 17), (255, 255, 255))
        self.assertEqual(icons.home(18, 25), (0, 0, 0))
        self.assertEqual(icons.home(18, 7), (255, 255, 255))
        self.assertEqual(icons.home(15, 16.5), (255, 255, 255))

    def test_home_sides_curve_toward_a_sharp_tip(self):
        self.assertEqual(icons.home(11, 22), (0, 0, 0))
        self.assertEqual(icons.home(25, 22), (0, 0, 0))
        self.assertIsNone(icons.home(9, 22))
        self.assertIsNone(icons.home(27, 22))
        self.assertIsNone(icons.home(17.5, 29.8))
        self.assertIsNone(icons.home(18.5, 29.8))

    def test_home_mask_has_outline_and_inner_disc(self):
        for offset in (-10, 10):
            self.assertEqual(icons.home(18 + offset, 12), (0, 0, 0))
        for offset in (-7, 7):
            self.assertEqual(icons.home(18 + offset, 12), (255, 255, 255))
        self.assertIsNone(icons.home(18, 0))
        colors = {icons.home(x + 0.5, y + 0.5) for x in range(36) for y in range(36)}
        self.assertEqual(colors, {None, (0, 0, 0), (255, 255, 255)})

    def test_original_home_artwork_is_native_size_rgba(self):
        assets = Path(__file__).resolve().parents[1] / "src/WIDGETS/AeroGrid/assets"
        content = (assets / "map-home.png").read_bytes()
        self.assertEqual(content, icons.render(52, icons.home_marker()))
        self.assertEqual(struct.unpack(">IIBBBBB", content[16:29]),
                         (52, 52, 8, 6, 0, 0, 0))

    def test_home_has_colored_symbol_inside_dark_disc(self):
        styled = icons.styled(icons.home, 12, icons.HOME_COLOR)
        self.assertEqual(styled(24, 24), icons.HOME_COLOR)
        self.assertEqual(styled(33, 24), (34, 39, 39))
        self.assertEqual(styled(37, 24), icons.HOME_COLOR)
        self.assertEqual(styled(39.5, 24), (34, 39, 39))
        self.assertIsNone(styled(40.5, 24))
        self.assertIsNone(styled(43, 24))
        for y in range(52):
            for x in range(52):
                if icons.sized(icons.home, 12)(x + 0.5, y + 0.5) is not None:
                    self.assertIsNotNone(styled(x + 0.5, y + 0.5))

    def test_tiles_are_deterministic_rgb_and_share_coverage(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            west, north = generator.generate(output)
            files = sorted(output.rglob("*.jpg"))
            self.assertEqual(len(files), 20)
            manifest = (output / "areas" / "synthetic.yaml").read_text()
            self.assertIn("version: 2\n", manifest)
            self.assertIn('name: "Synthetic test area"\n', manifest)
            self.assertIn("  radio: tx16s\n", manifest)
            self.assertIn("  coverageMode: full-area-clamped\n", manifest)
            self.assertIn(f"xMin: {west * 2}", manifest)
            self.assertIn(f"xMax: {(west + 2) * 2 - 1}", manifest)
            self.assertIn(f"yMin: {north * 2}", manifest)
            self.assertIn(f"yMax: {(north + 2) * 2 - 1}", manifest)
            for path in files:
                content = path.read_bytes()
                image = Image.open(BytesIO(content))
                image.load()
                self.assertEqual(image.size, (256, 256))
                self.assertEqual(image.mode, "RGB")
                zoom, x, y = int(path.parts[-3]), int(path.parts[-2]), int(path.stem)
                factor = 2 ** (zoom - generator.ZOOM)
                yellow = (240, 183, 65)
                def pixel(px, py):
                    return image.getpixel((px, py))
                def assert_yellow(value):
                    self.assertLess(max(abs(a - b) for a, b in zip(value, yellow)), 45)
                for position in range(256):
                    assert_yellow(pixel(position, 0))
                    assert_yellow(pixel(0, position))
                    if x == (west + 2) * factor - 1:
                        assert_yellow(pixel(255, position))
                        assert_yellow(pixel(254, position))
                    if y == (north + 2) * factor - 1:
                        assert_yellow(pixel(position, 255))
                        assert_yellow(pixel(position, 254))
            first = files[0].read_bytes()
            generator.generate(output)
            self.assertEqual(files[0].read_bytes(), first)


if __name__ == "__main__":
    unittest.main()

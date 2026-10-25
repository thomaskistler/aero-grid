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
        image = Image.open(BytesIO(icons.render(52, icons.home_marker())))
        self.assertEqual(image.getchannel("A").getbbox(), (4, 4, 48, 48))

    def test_home_circle_matches_runtime_centre_anchor(self):
        sample = icons.home_marker()
        for dx, dy in ((-1, 0), (1, 0), (0, -1), (0, 1)):
            self.assertEqual(sample(26 + dx * 22, 26 + dy * 22),
                             (*icons.WHITE, 170))
            self.assertEqual(sample(26 + dx * 22.1, 26 + dy * 22.1),
                             (0, 0, 0, 0))

    def test_home_has_red_house_and_translucent_white_disc(self):
        sample = icons.home_marker()
        self.assertEqual(sample(26, 20), (*icons.HOME_COLOR, 255))
        self.assertEqual(sample(22, 34), (*icons.HOME_COLOR, 255))
        self.assertEqual(sample(7, 26), (*icons.WHITE, 170))
        colors = {sample(x + 0.5, y + 0.5) for x in range(52) for y in range(52)}
        self.assertEqual(colors, {(0, 0, 0, 0), (*icons.WHITE, 170),
                                  (*icons.HOME_COLOR, 255)})

    def test_home_arched_door_reveals_disc(self):
        sample = icons.home_marker()
        for x, y in ((26, 29), (26, 31), (26, 36)):
            self.assertEqual(sample(x, y), (*icons.WHITE, 170))
        for x, y in ((24, 28), (22, 34), (30, 34)):
            self.assertEqual(sample(x, y), (*icons.HOME_COLOR, 255))

    def test_original_home_artwork_is_native_size_rgba(self):
        assets = Path(__file__).resolve().parents[1] / "src/WIDGETS/AeroGrid/assets"
        content = (assets / "map-home.png").read_bytes()
        self.assertEqual(content, icons.render(52, icons.home_marker()))
        self.assertEqual(struct.unpack(">IIBBBBB", content[16:29]),
                         (52, 52, 8, 6, 0, 0, 0))

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

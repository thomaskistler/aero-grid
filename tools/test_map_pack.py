# SPDX-License-Identifier: GPL-2.0-only
"""Exercise actual browser exports with the radio's YAML/parser geometry code."""
import math
from io import BytesIO
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import zipfile
from PIL import Image

from lupa.lua53 import LuaRuntime


ROOT = Path(__file__).resolve().parents[1]


class BrowserPackTests(unittest.TestCase):
    def test_exports_decode_and_load_on_radio(self):
        with tempfile.TemporaryDirectory() as directory:
            subprocess.run(
                [os.environ.get("NODE", "node"), str(ROOT / "tools/test_map_pack.js"), directory],
                check=True, cwd=ROOT, capture_output=True, text=True)
            lua = LuaRuntime(unpack_returned_tuples=True)
            lua.execute('debug.setmetatable("", nil)')
            yaml = lua.execute(
                f'return assert(loadfile("{ROOT}/src/WIDGETS/AeroGrid/lib/yaml.lua"))()')
            radio = lua.execute(
                f'return assert(loadfile("{ROOT}/src/WIDGETS/AeroGrid/panels/map-prototype.lua"))()')
            seen = {}
            for archive_path in sorted(Path(directory).glob("*.zip")):
                with self.subTest(area=archive_path.stem), zipfile.ZipFile(archive_path) as archive:
                    self.assertIsNone(archive.testzip())
                    names = archive.namelist()
                    self.assertEqual(len(names), len(set(names)))
                    manifest_text = archive.read(
                        f"AEROGRID/maps/areas/{archive_path.stem}.yaml").decode("ascii")
                    parsed = yaml.parse(manifest_text)
                    manifest = parsed[0] if isinstance(parsed, tuple) else parsed
                    self.assertIsNotNone(manifest)
                    radio.validatePack(manifest)
                    self.assertEqual(manifest.id, archive_path.stem)
                    tile_count = 0
                    for index in range(1, len(manifest.levels) + 1):
                        level = manifest.levels[index]
                        for x in range(level.xMin, level.xMax + 1):
                            for y in range(level.yMin, level.yMax + 1):
                                name = (f"AEROGRID/maps/tiles/{manifest.imagerySet}/"
                                        f"{level.zoom}/{x % 2**level.zoom}/{y}.jpg")
                                image = archive.read(name)
                                self.assertEqual(manifest.imageFormat, "jpeg")
                                decoded = Image.open(BytesIO(image))
                                decoded.load()
                                self.assertEqual(decoded.size, (256, 256))
                                self.assertEqual(decoded.mode, "RGB")
                                self.assertTrue(radio.jpegHeader(image[:4096]))
                                if name in seen:
                                    self.assertEqual(image, seen[name])
                                seen[name] = image
                                tile_count += 1
                        # Centre of coverage projects to its tile-local centre,
                        # even when canonical longitude is across the date line.
                        n = 2 ** level.zoom
                        center_x = (level.xMin + level.xMax + 1) / 2
                        center_y = (level.yMin + level.yMax + 1) / 2
                        longitude = (center_x / n * 360) % 360 - 180
                        latitude = math.degrees(math.atan(math.sinh(
                            math.pi * (1 - 2 * center_y / n))))
                        px, py = radio.project(level, latitude, longitude)
                        self.assertAlmostEqual(px, (center_x - level.xMin) * 256, places=5)
                        self.assertAlmostEqual(py, (center_y - level.yMin) * 256, places=5)
                    self.assertEqual(sum(name.endswith(".jpg") for name in names), tile_count)
                    self.assertTrue(all(name.startswith("AEROGRID/maps/") for name in names))


if __name__ == "__main__":
    unittest.main()

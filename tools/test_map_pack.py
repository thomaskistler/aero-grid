# SPDX-License-Identifier: GPL-2.0-only
"""Validate browser archives independently; optionally exercise a pinned radio reader."""
import math
from io import BytesIO
import os
import json
import re
from pathlib import Path
import subprocess
import tempfile
import unittest
import zipfile
from PIL import Image

from lupa.lua53 import LuaRuntime


ROOT = Path(__file__).resolve().parents[1]


class BrowserPackTests(unittest.TestCase):
    def test_exports_decode_and_satisfy_contract(self):
        with tempfile.TemporaryDirectory() as directory:
            subprocess.run(
                [os.environ.get("NODE", "node"), str(ROOT / "tools/test_map_pack.js"), directory],
                check=True, cwd=ROOT, capture_output=True, text=True)
            lua = LuaRuntime(unpack_returned_tuples=True)
            lua.execute('debug.setmetatable("", nil)')
            yaml = lua.execute(
                f'return assert(loadfile("{ROOT}/src/WIDGETS/AeroGrid/lib/yaml.lua"))()')
            radio_path = os.environ.get("MAP_RADIO_SOURCE")
            radio = None
            if radio_path:
                radio = lua.execute(Path(radio_path).read_text(encoding="ascii"))
            expected = json.loads((ROOT / "tools/fixtures/map-area-contract-v1.json").read_text())
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
                    self.assertEqual(manifest.format, "aerogrid-map-area")
                    self.assertEqual(manifest.version, 1)
                    self.assertEqual(manifest.imageFormat, "jpeg")
                    self.assertEqual(manifest.projection, "EPSG:3857")
                    self.assertEqual(manifest.tileScheme, "XYZ")
                    self.assertEqual(manifest.tileSize, 256)
                    self.assertLessEqual(len(manifest_text), 8192)
                    self.assertRegex(manifest.imagerySet, r"^[a-z0-9_-]{1,32}$")
                    self.assertEqual(manifest.id, archive_path.stem)
                    levels = [{key: level[key] for key in ("zoom", "xMin", "xMax", "yMin", "yMax")}
                              for level in (manifest.levels[index] for index in range(1, len(manifest.levels) + 1))]
                    self.assertEqual(levels, expected[archive_path.stem])
                    if radio:
                        radio.validatePack(manifest)
                    self.assertTrue(1 <= len(levels) <= 9)
                    source = json.loads(archive.read(f"AEROGRID/maps/sources/{manifest.imagerySet}.json"))
                    self.assertEqual(source["id"], manifest.imagerySet)
                    self.assertTrue(source["synthetic"])
                    for key in ("source", "edition", "conversion", "license", "attribution"):
                        self.assertTrue(source[key])
                    previous = None
                    tile_count = 0
                    for index in range(1, len(manifest.levels) + 1):
                        level = manifest.levels[index]
                        self.assertTrue(11 <= level.zoom <= 19)
                        if previous is not None:
                            self.assertEqual(level.zoom, previous + 1)
                        previous = level.zoom
                        n = 2 ** level.zoom
                        self.assertTrue(0 <= level.xMin < n)
                        self.assertTrue(level.xMin <= level.xMax < level.xMin + n - 1)
                        self.assertTrue(0 <= level.yMin <= level.yMax < n)
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
                                self.assertFalse(decoded.getexif())
                                self.assertTrue(image.startswith(b"\xff\xd8"))
                                self.assertTrue(image.endswith(b"\xff\xd9"))
                                self.assertIn(b"\xff\xda", image[:4096])
                                self.assertIn(b"\xff\xc0\x00\x11\x08\x01\x00\x01\x00\x03", image[:4096])
                                self.assertLessEqual(len(image), 256 * 1024)
                                if radio:
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
                        if radio:
                            px, py = radio.project(level, latitude, longitude)
                            self.assertAlmostEqual(px, (center_x - level.xMin) * 256, places=5)
                            self.assertAlmostEqual(py, (center_y - level.yMin) * 256, places=5)
                    self.assertEqual(sum(name.endswith(".jpg") for name in names), tile_count)
                    self.assertLessEqual(tile_count, 2000)
                    self.assertEqual(len(names), tile_count + 3)
                    self.assertLessEqual(sum(archive.getinfo(name).file_size for name in names), 128 * 1024 * 1024)
                    self.assertTrue(all(name.startswith("AEROGRID/maps/") for name in names))
                    self.assertFalse(any(".." in name or re.search(r"\\", name) for name in names))
            self.assertEqual({path.stem for path in Path(directory).glob("*.zip")}, set(expected))


if __name__ == "__main__":
    unittest.main()

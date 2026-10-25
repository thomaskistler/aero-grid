# SPDX-License-Identifier: GPL-2.0-only
import json
from pathlib import Path
import unittest

from PIL import Image, ImageStat


ROOT = Path(__file__).resolve().parents[1] / "tests/fixtures/map-imagery"


class MapImageryTests(unittest.TestCase):
    def test_stored_tiles(self):
        source = json.loads((ROOT / "source.json").read_text())
        tiles = list((ROOT / "tiles" / source["imagerySet"]).rglob("*.jpg"))
        self.assertEqual(len(tiles), 20)
        for tile in tiles:
            with Image.open(tile) as image:
                image.load()
                self.assertEqual(image.size, (256, 256))
                self.assertEqual(image.mode, "RGB")
                self.assertFalse(image.getexif())
                self.assertGreater(max(ImageStat.Stat(image).stddev), 5)

    def test_manifest_references_stored_coverage(self):
        source = json.loads((ROOT / "source.json").read_text())
        manifest = (ROOT / "areas/companion-naip.yaml").read_text()
        self.assertIn("version: 2\n", manifest)
        self.assertIn(f"imagerySet: {source['imagerySet']}\n", manifest)
        for zoom, west, north, count in ((16, 15080, 27863, 2), (17, 30160, 55726, 4)):
            for x in range(west, west + count):
                for y in range(north, north + count):
                    self.assertTrue((ROOT / "tiles" / source["imagerySet"] / str(zoom) / str(x) / f"{y}.jpg").is_file())

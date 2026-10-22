# SPDX-License-Identifier: GPL-2.0-only
import importlib.util
import math
from pathlib import Path
import struct
import unittest
import zlib

spec = importlib.util.spec_from_file_location("aircraft", Path(__file__).with_name("generate-aircraft-icons.py"))
aircraft = importlib.util.module_from_spec(spec)
spec.loader.exec_module(aircraft)
ASSETS = Path(__file__).resolve().parents[1] / "src/WIDGETS/AeroGrid/assets"


def pixels(content, size):
    assert struct.unpack(">IIBBBBB", content[16:29]) == (size, size, 8, 6, 0, 0, 0)
    data, offset = bytearray(), 8
    while offset < len(content):
        length = struct.unpack(">I", content[offset:offset + 4])[0]
        kind = content[offset + 4:offset + 8]
        payload = content[offset + 8:offset + 8 + length]
        checksum = struct.unpack(">I", content[offset + 8 + length:offset + 12 + length])[0]
        assert checksum == zlib.crc32(kind + payload)
        if kind == b"IDAT":
            data.extend(payload)
        offset += length + 12
    rows = zlib.decompress(data)
    assert len(rows) == size * (1 + size * 4)
    result = []
    for y in range(size):
        assert rows[y * (1 + size * 4)] == 0
        start = y * (1 + size * 4) + 1
        result.append([tuple(rows[start + x * 4:start + (x + 1) * 4]) for x in range(size)])
    return result


class AircraftTests(unittest.TestCase):
    def test_complete_headings_and_transparent_unclipped_edges(self):
        files = sorted(ASSETS.glob("map-aircraft-*.png"))
        self.assertEqual([p.name for p in files],
                         [f"map-aircraft-{h:03d}.png" for h in range(0, 360, 10)])
        for path in files + [ASSETS / "map-follow.png"]:
            size = 24 if path.name == "map-follow.png" else 52
            image = pixels(path.read_bytes(), size)
            self.assertTrue(all(p[3] == 0 for p in image[0] + image[-1]))
            if size == 52:
                self.assertTrue(all(row[0][3] == row[-1][3] == 0 for row in image))
            else:
                self.assertTrue(all(row[0][3] <= 85 and row[-1][3] <= 85 for row in image))
                sample = aircraft.sample(24, 22, aircraft.WHITE)
                for y in range(24):
                    self.assertEqual(sample(0, y)[3], 0)
                    self.assertEqual(sample(24, y)[3], 0)
            self.assertTrue(any(p[3] == 255 for row in image for p in row))
        self.assertLess(sum(p.stat().st_size for p in files), 64 * 1024)

    def test_approved_north_and_follow_are_reproducible(self):
        for name, size, width, color in (
                ("map-aircraft-000.png", 52, 38, aircraft.CYAN),
                ("map-follow.png", 24, 22, aircraft.WHITE)):
            self.assertEqual((ASSETS / name).read_bytes(),
                             aircraft.render(size, aircraft.sample(size, width, color)))
            image = pixels((ASSETS / name).read_bytes(), size)
            columns = [x for x in range(size)
                       if any(row[x][:3] == color and row[x][3] > 100 for row in image)]
            self.assertTrue(width - 3 <= max(columns) - min(columns) + 1 <= width)

    def test_rotations_are_clockwise_about_image_centre(self):
        north = aircraft.sample(52, 38, aircraft.CYAN)
        for heading in range(0, 360, 10):
            rotated = aircraft.sample(52, 38, aircraft.CYAN, heading)
            sine, cosine = math.sin(math.radians(heading)), math.cos(math.radians(heading))
            for x, y in ((0, -10), (10, -4), (-10, -4), (0, 12), (16, 0), (21, 21)):
                self.assertEqual(rotated(26 + x * cosine - y * sine, 26 + x * sine + y * cosine),
                                 north(26 + x, 26 + y))

    def test_fuselage_separation_and_subtle_shadow(self):
        pixel = aircraft.sample(52, 38, aircraft.CYAN)
        scale = 38 / 194
        def at(x, y):
            return pixel(26 + (x - 113) * scale, 26 + (y - 92) * scale)
        self.assertEqual(at(113, 65), (*aircraft.CYAN, 255))
        self.assertEqual(at(101.7, 65), (*aircraft.DARK, 255))
        self.assertEqual(at(124.7, 65), (*aircraft.DARK, 255))
        self.assertEqual(at(70, 65), (*aircraft.CYAN, 255))
        self.assertEqual(at(12, 65), (0, 0, 0, 90))
        self.assertEqual(at(5, 65), (0, 0, 0, 0))
        self.assertTrue(aircraft.icons.polygon(100, 160, aircraft.TAIL))
        self.assertFalse(aircraft.icons.polygon(100, 165, aircraft.TAIL))


if __name__ == "__main__":
    unittest.main()

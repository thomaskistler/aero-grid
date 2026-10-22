# SPDX-License-Identifier: GPL-2.0-only
"""Generate original, georeferenced RGB test tiles. No imagery is downloaded."""
import argparse
from io import BytesIO
import math
from pathlib import Path
from PIL import Image


LATITUDE = 25.9973
LONGITUDE = -97.1572
ZOOM = 16
SIZE = 256
IMAGERY_SET = "companion-v1-jpeg-v1"
DIGITS = (
    ("111", "101", "101", "101", "111"),
    ("010", "110", "010", "010", "111"),
    ("111", "001", "111", "100", "111"),
    ("111", "001", "111", "001", "111"),
    ("101", "101", "111", "001", "001"),
    ("111", "100", "111", "001", "111"),
    ("111", "100", "111", "101", "111"),
    ("111", "001", "010", "010", "010"),
    ("111", "101", "111", "101", "111"),
    ("111", "101", "111", "001", "111"),
)


def jpeg(rgb):
    output = BytesIO()
    Image.frombytes("RGB", (SIZE, SIZE), bytes(rgb)).save(
        output, format="JPEG", quality=90, subsampling=0)
    return output.getvalue()


def tile_image(zoom, x, y, west, north):
    factor = 2 ** (zoom - ZOOM)
    rgb = bytearray()
    for py in range(SIZE):
        for px in range(SIZE):
            gx = ((x - west * factor) * SIZE + px) / factor
            gy = ((y - north * factor) * SIZE + py) / factor
            shade = int(gx // 32 + gy // 32) % 2
            color = (57 + shade * 13, 82 + shade * 13, 46 + shade * 8)
            if abs(gx - 250 - 65 * math.sin(gy / 80)) < 11:
                color = (45, 114, 170)
            if abs(gy - gx * 0.55 - 80) < 4 or abs(gx - 110) < 3:
                color = (204, 194, 164)
            if (px < 2 or py < 2
                    or (x == (west + 2) * factor - 1 and px >= SIZE - 2)
                    or (y == (north + 2) * factor - 1 and py >= SIZE - 2)):
                color = (240, 183, 65)
            rgb.extend(color)
    text = f"{zoom}/{x}/{y}"
    for index, char in enumerate(text):
        glyph = DIGITS[int(char)] if char.isdigit() else ("001", "001", "010", "100", "100")
        for row, bits in enumerate(glyph):
            for col, bit in enumerate(bits):
                if bit == "1":
                    for dy in range(2):
                        for dx in range(2):
                            offset = ((10 + row * 2 + dy) * SIZE + 8 + index * 8 + col * 2 + dx) * 3
                            rgb[offset:offset + 3] = b"\xff\xff\xff"
    return jpeg(rgb)


def generate(output):
    output = Path(output)
    # A 2x2 overview and a 4x4 detail level cover exactly the same rectangle.
    n = 2 ** ZOOM
    west = math.floor((LONGITUDE + 180) / 360 * n + 0.5) - 1
    north = math.floor((1 - math.asinh(math.tan(math.radians(LATITUDE))) / math.pi) / 2 * n + 0.5) - 1
    manifest = ("format: aerogrid-map-area\nversion: 1\nid: synthetic\n"
                f"imagerySet: {IMAGERY_SET}\nprojection: EPSG:3857\n"
                "tileScheme: XYZ\ntileSize: 256\nimageFormat: jpeg\nlevels:\n")
    for zoom in (ZOOM, ZOOM + 1):
        factor = 2 ** (zoom - ZOOM)
        x_min, y_min = west * factor, north * factor
        x_max, y_max = (west + 2) * factor - 1, (north + 2) * factor - 1
        manifest += (f"  - zoom: {zoom}\n    xMin: {x_min}\n    xMax: {x_max}\n"
                     f"    yMin: {y_min}\n    yMax: {y_max}\n")
        for x in range(x_min, x_max + 1):
            directory = output / "tiles" / IMAGERY_SET / str(zoom) / str(x)
            directory.mkdir(parents=True, exist_ok=True)
            for y in range(y_min, y_max + 1):
                (directory / f"{y}.jpg").write_bytes(tile_image(zoom, x, y, west, north))
    (output / "areas").mkdir(parents=True, exist_ok=True)
    (output / "areas" / "synthetic.yaml").write_text(manifest, encoding="ascii")
    return west, north


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True,
                        help="Map library directory, e.g. build/sdcard/AEROGRID/maps")
    args = parser.parse_args()
    generate(args.output)
    print(f"Generated 20 synthetic RGB tiles at {args.output}")
    print(f"GPS sample: {LATITUDE}, {LONGITUDE}; zoom levels 16 and 17")


if __name__ == "__main__":
    main()

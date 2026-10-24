# SPDX-License-Identifier: GPL-2.0-only
"""Render original map marker artwork as small, native-size RGBA PNGs."""
import argparse
from pathlib import Path
import struct
import zlib


WHITE = (255, 255, 255)
HOME_COLOR = (236, 72, 62)
HOUSE = [(13, 76 / 3), (26, 43 / 3), (39, 76 / 3),
         (36, 76 / 3), (36, 37), (16, 37), (16, 76 / 3)]


def polygon(x, y, points):
    inside = False
    previous = points[-1]
    for current in points:
        ax, ay = previous
        bx, by = current
        if (ay > y) != (by > y) and x < (bx - ax) * (y - ay) / (by - ay) + ax:
            inside = not inside
        previous = current
    return inside


def render(size, sample):
    scale = 3
    pixels = bytearray()
    for y in range(size):
        for x in range(size):
            samples = [sample(x + (sx + 0.5) / scale, y + (sy + 0.5) / scale)
                       for sy in range(scale) for sx in range(scale)]
            alpha = sum(color[3] for color in samples)
            if alpha:
                pixels.extend(round(sum(color[channel] * color[3] for color in samples) / alpha)
                              for channel in range(3))
                pixels.append(round(alpha / len(samples)))
            else:
                pixels.extend((0, 0, 0, 0))
    def chunk(kind, data):
        return (struct.pack(">I", len(data)) + kind + data
                + struct.pack(">I", zlib.crc32(kind + data)))
    rows = b"".join(b"\0" + pixels[y * size * 4:(y + 1) * size * 4] for y in range(size))
    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


def home_marker():
    def pixel(x, y):
        doorway = (x - 26) ** 2 + (y - 31) ** 2 <= 3 * 3 or (23 <= x <= 29 and y >= 31)
        if polygon(x, y, HOUSE) and not doorway:
            return (*HOME_COLOR, 255)
        if (x - 26) ** 2 + (y - 26) ** 2 <= 22 * 22:
            return (*WHITE, 170)
        return (0, 0, 0, 0)
    return pixel


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / "map-home.png").write_bytes(render(52, home_marker()))


if __name__ == "__main__":
    main()

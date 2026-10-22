# SPDX-License-Identifier: GPL-2.0-only
"""Render original map marker artwork as small, native-size RGBA PNGs."""
import argparse
import math
from pathlib import Path
import struct
import zlib


INK = (0, 0, 0)
WHITE = (255, 255, 255)
HOME_COLOR = (255, 118, 46)
OUTER_RADIUS = 11
INNER_RADIUS = 8
PIN_SIDE = [(7 + 11 * (step / 48) ** 2, 12 + 18 * step / 48)
            for step in range(49)]
PIN_TAIL = PIN_SIDE + [(36 - x, y) for x, y in reversed(PIN_SIDE[:-1])]


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
            opaque = [color for color in samples if color]
            if opaque:
                pixels.extend(round(sum(color[channel] for color in opaque) / len(opaque))
                              for channel in range(3))
                pixels.append(round(255 * len(opaque) / len(samples)))
            else:
                pixels.extend((0, 0, 0, 0))
    def chunk(kind, data):
        return (struct.pack(">I", len(data)) + kind + data
                + struct.pack(">I", zlib.crc32(kind + data)))
    rows = b"".join(b"\0" + pixels[y * size * 4:(y + 1) * size * 4] for y in range(size))
    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


def home(x, y):
    radius = ((x - 18) ** 2 + (y - 12) ** 2) ** 0.5
    body = radius <= OUTER_RADIUS or polygon(x, y, PIN_TAIL)
    if not body:
        return None
    if radius >= INNER_RADIUS:
        return INK
    if polygon(x, y, [(12.5, 12), (18, 8), (23.5, 12), (22, 12),
                       (22, 16), (19, 16), (19, 13), (17, 13),
                       (17, 16), (14, 16), (14, 12)]):
        return INK
    return WHITE


def sized(sample, center_y):
    def scaled(x, y):
        return sample(18 + (x - 24) * 11 / 16,
                      center_y + (y - 24) * 11 / 16)
    return scaled


def styled(sample, center_y, color):
    shape = sized(sample, center_y)
    directions = [(math.cos(step * math.pi / 8), math.sin(step * math.pi / 8))
                  for step in range(16)]
    def colored(x, y):
        value = shape(x, y)
        neighbors = [shape(x + dx * 1.25, y + dy * 1.25)
                     for dx, dy in directions]
        if value is None:
            return None
        if any(point is None for point in neighbors):
            return (34, 39, 39)
        radius = ((x - 24) ** 2 + (y - 24) ** 2) ** 0.5
        if radius < INNER_RADIUS * 16 / 11:
            return color if value == INK else (34, 39, 39)
        return color
    return colored


def home_marker():
    shape = styled(home, 12, HOME_COLOR)
    def scaled(x, y):
        return shape(24 + (x - 24) / 0.85, 50 + (y - 50) / 0.85)
    return scaled


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / "map-home.png").write_bytes(render(52, home_marker()))


if __name__ == "__main__":
    main()

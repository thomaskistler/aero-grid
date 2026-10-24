# SPDX-License-Identifier: GPL-2.0-only
"""Generate native-size aircraft PNGs, pre-rotated clockwise from north."""
import argparse
from concurrent.futures import ProcessPoolExecutor
import importlib.util
import math
from pathlib import Path
import struct
import zlib

spec = importlib.util.spec_from_file_location("map_icons", Path(__file__).with_name("generate-map-icons.py"))
icons = importlib.util.module_from_spec(spec)
spec.loader.exec_module(icons)

CYAN = (112, 214, 243)
WHITE = (255, 255, 255)
DARK = (24, 46, 55)
BLUE = (50, 139, 238)
ARROW = [(26, 11), (38, 37), (26, 32), (14, 37)]
WINGS = [(16, 58), (101, 49), (125, 49), (210, 58),
         (210, 82), (126, 97), (100, 97), (16, 82)]
TAIL = [(74, 141), (104, 133), (122, 133), (152, 141),
        (152, 159), (125, 164), (119, 150), (113, 174),
        (107, 150), (101, 164), (74, 159)]
BODY = [(113, 19), (120, 20), (124, 23), (126, 30),
        (126, 49), (123, 87), (119, 127), (117, 147),
        (113, 174), (109, 147), (107, 127), (103, 87),
        (100, 49), (100, 30), (102, 23), (106, 20)]
PROPELLER = [(84, 13), (92, 11.5), (134, 11.5), (142, 13),
             (142, 15), (134, 16), (92, 16), (84, 15)]
SPINNER = [(108, 18), (108, 13), (111, 7), (113, 5),
           (115, 7), (118, 13), (118, 18)]


def near(x, y, points, width):
    for a, b in zip(points, points[1:] + [points[0]]):
        dx, dy = b[0] - a[0], b[1] - a[1]
        t = max(0, min(1, ((x - a[0]) * dx + (y - a[1]) * dy) / (dx * dx + dy * dy)))
        if (x - a[0] - t * dx) ** 2 + (y - a[1] - t * dy) ** 2 <= width * width:
            return True
    return False


def sample(size, width, fill, heading=0):
    scale = width / 194
    sine, cosine = math.sin(math.radians(heading)), math.cos(math.radians(heading))
    def pixel(x, y):
        dx, dy = x - size / 2, y - size / 2
        sx = (dx * cosine + dy * sine) / scale + 113
        sy = (-dx * sine + dy * cosine) / scale + 92
        color = None
        for polygon in (PROPELLER, SPINNER, WINGS, TAIL):
            if icons.polygon(sx, sy, polygon):
                color = fill
            if near(sx, sy, polygon, 0.45 / scale):
                color = DARK
        if icons.polygon(sx, sy, BODY):
            color = fill
        if near(sx, sy, BODY, 0.5 / scale):
            color = DARK
        if color is not None:
            return (*color, 255)
        if fill == CYAN and any(near(sx, sy, p, 1.45 / scale)
                                for p in (PROPELLER, SPINNER, WINGS, TAIL, BODY)):
            return (0, 0, 0, 90)
        return (0, 0, 0, 0)
    return pixel


def render(size, pixel):
    rows = bytearray()
    for y in range(size):
        rows.append(0)
        for x in range(size):
            samples = [pixel(x + (sx + 0.5) / 3, y + (sy + 0.5) / 3)
                       for sy in range(3) for sx in range(3)]
            alpha = sum(value[3] for value in samples)
            if alpha:
                rows.extend(round(sum(value[c] * value[3] for value in samples) / alpha)
                            for c in range(3))
                rows.append(round(alpha / 9))
            else:
                rows.extend((0, 0, 0, 0))
    def chunk(kind, data):
        return (struct.pack(">I", len(data)) + kind + data
                + struct.pack(">I", zlib.crc32(kind + data)))
    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


def arrow_sample(heading=0):
    sine, cosine = math.sin(math.radians(heading)), math.cos(math.radians(heading))
    def pixel(x, y):
        dx, dy = x - 26, y - 26
        sx, sy = 26 + dx * cosine + dy * sine, 26 - dx * sine + dy * cosine
        if icons.polygon(sx, sy, ARROW):
            return (*BLUE, 255)
        if dx * dx + dy * dy <= 22 * 22:
            return (*WHITE, 210)
        return (0, 0, 0, 0)
    return pixel


def write_heading(args):
    output, heading = args
    (output / f"map-aircraft-{heading:03d}.png").write_bytes(render(52, sample(52, 38, CYAN, heading)))
    (output / f"map-arrow-{heading:03d}.png").write_bytes(render(52, arrow_sample(heading)))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    with ProcessPoolExecutor(max_workers=4) as pool:
        list(pool.map(write_heading, ((args.output, h) for h in range(0, 360, 10))))
    (args.output / "map-follow.png").write_bytes(render(24, sample(24, 22, WHITE)))


if __name__ == "__main__":
    main()

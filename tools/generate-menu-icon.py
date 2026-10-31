# SPDX-License-Identifier: GPL-2.0-only
"""Generate native-sized menu artwork with EdgeTX's exact 8-bit silhouette.

Uses macOS sips, as used for local asset conversion, and the official GPL-2.0
EdgeTX v2.12.0 masks. No third-party artwork or rendering service is involved.
"""
import struct
import subprocess
import urllib.request
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SIZES = {"320x240": 36, "480x272": 45, "800x480": 62}


def asset_name(size):
    return f"aerogrid-mark-{size}.png"


SOURCE = "https://raw.githubusercontent.com/EdgeTX/edgetx/v2.12.0/radio/src/bitmaps"


def read_png(path):
    """Read the non-interlaced RGB/RGBA PNGs produced by sips and EdgeTX."""
    data = path.read_bytes()
    assert data[:8] == b"\x89PNG\r\n\x1a\n"
    offset, compressed = 8, bytearray()
    while offset < len(data):
        length = struct.unpack_from(">I", data, offset)[0]
        kind, payload = data[offset + 4:offset + 8], data[offset + 8:offset + 8 + length]
        if kind == b"IHDR":
            width, height, depth, color, compression, filtering, interlace = struct.unpack(">IIBBBBB", payload)
            assert depth == 8 and color in (2, 6) and (compression, filtering, interlace) == (0, 0, 0)
        elif kind == b"IDAT":
            compressed.extend(payload)
        offset += length + 12
    channels = 3 if color == 2 else 4
    raw, rows, previous = zlib.decompress(compressed), [], bytearray(width * channels)
    stride = width * channels
    for y in range(height):
        method = raw[y * (stride + 1)]
        row = bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        for x in range(stride):
            left = row[x - channels] if x >= channels else 0
            above, corner = previous[x], previous[x - channels] if x >= channels else 0
            if method == 4:
                p = left + above - corner
                distances = (abs(p - left), abs(p - above), abs(p - corner))
                prediction = (left, above, corner)[distances.index(min(distances))]
            else:
                assert method in (0, 1, 2, 3)
                prediction = (0, left, above, (left + above) // 2)[method]
            row[x] = (row[x] + prediction) & 255
        rows.append([tuple(row[x:x + channels]) for x in range(0, stride, channels)])
        previous = row
    return rows


def write_png(path, rows):
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    width, height = len(rows[0]), len(rows)
    raw = b"".join(b"\0" + bytes(component for pixel in row for component in pixel) for row in rows)
    path.write_bytes(b"\x89PNG\r\n\x1a\n"
                     + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
                     + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


def mask_rectangles(mask):
    """Merge equal-alpha row runs without changing native edge coverage."""
    rectangles, previous = [], {}
    for y, row in enumerate(mask):
        current, x = {}, 0
        while x < len(row):
            alpha = 255 - row[x][0]
            end = x + 1
            while end < len(row) and 255 - row[end][0] == alpha:
                end += 1
            if alpha:
                key = (x, end - x, alpha)
                if key in previous:
                    index = previous[key]
                    rectangles[index][3] += 1
                else:
                    index = len(rectangles)
                    rectangles.append([x, y, end - x, 1, alpha])
                current[key] = index
            x = end
        previous = current
    return rectangles


def generate():
    output = ROOT / "build/native-logo"
    output.mkdir(parents=True, exist_ok=True)
    assets = ROOT / "src/WIDGETS/AeroGrid/assets"
    masks = []
    for display, size in SIZES.items():
        mask_path = output / f"{display}.png"
        urllib.request.urlretrieve(f"{SOURCE}/{display}/default_theme/mask_topleft.png", mask_path)
        mask = read_png(mask_path)
        assert len(mask) == size and len(mask[0]) == size
        packed = "".join("\\" + str(value) for rectangle in mask_rectangles(mask) for value in rectangle)
        masks.append(f'    [{size}] = "{packed}",')
        rendered = output / f"mark-{size}.png"
        subprocess.run(["sips", "-s", "format", "png", "-z", str(size), str(size),
                        str(assets / "aerogrid.svg"), "--out", str(rendered)], check=True,
                       stdout=subprocess.DEVNULL)
        artwork = read_png(rendered)
        rows = []
        for y in range(size):
            row = []
            for x in range(size):
                # Native encode-bitmap.py encode_8bits uses 255 - grayscale.
                silhouette = 255 - mask[y][x][0]
                pixel = artwork[y][x]
                coverage = pixel[3] if len(pixel) == 4 else 255
                row.append((*pixel[:3], (coverage * silhouette + 127) // 255))
            rows.append(row)
        write_png(assets / asset_name(size), rows)
    runtime = ROOT / "src/WIDGETS/AeroGrid/lib/aerogrid_menu.lua"
    source = runtime.read_text()
    start = source.index("-- BEGIN GENERATED ICON MASKS")
    end = source.index("-- END GENERATED ICON MASKS", start) + len("-- END GENERATED ICON MASKS")
    source = source[:start] + (
        "-- BEGIN GENERATED ICON MASKS (tools/generate-menu-icon.py)\n"
        "local ICON_MASKS = {\n" + "\n".join(masks) + "\n}\n"
        "-- END GENERATED ICON MASKS"
    ) + source[end:]
    runtime.write_text(source)


if __name__ == "__main__":
    generate()

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
# Runtime order matters: the menu picks the first background distinct from the
# active EdgeTX theme's FOCUS color, which fills the native top-left icon.
# Existing AeroGrid palette: Modern Dark activeBg/surface, Modern Light orange/green.
VARIANTS = {"blue": "#365673", "orange": "#c65b12", "green": "#147642", "slate": "#212830"}
MASTER_BACKGROUND = "#365673"


def asset_name(variant, size):
    return f"aerogrid-{variant}-{size}.png"
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


def generate():
    output = ROOT / "build/native-logo"
    output.mkdir(parents=True, exist_ok=True)
    assets = ROOT / "src/WIDGETS/AeroGrid/assets"
    master = (assets / "aerogrid.svg").read_text()
    assert master.count(MASTER_BACKGROUND) == 1
    for display, size in SIZES.items():
        mask_path = output / f"{display}.png"
        urllib.request.urlretrieve(f"{SOURCE}/{display}/default_theme/mask_topleft.png", mask_path)
        mask = read_png(mask_path)
        assert len(mask) == size and len(mask[0]) == size
        for variant, color in VARIANTS.items():
            source, rendered = output / f"{variant}.svg", output / f"{variant}-{size}.png"
            source.write_text(master.replace(MASTER_BACKGROUND, color))
            subprocess.run(["sips", "-s", "format", "png", "-z", str(size), str(size),
                            str(source), "--out", str(rendered)], check=True,
                           stdout=subprocess.DEVNULL)
            branding = read_png(rendered)
            background = tuple(int(color[i:i + 2], 16) for i in (1, 3, 5))
            rows = []
            for y in range(size):
                row = []
                for x in range(size):
                    # Native encode-bitmap.py encode_8bits uses 255 - grayscale.
                    alpha = 255 - mask[y][x][0]
                    pixel = branding[y][x]
                    # SVG coverage must not multiply the native edge's alpha.
                    rgb = pixel[:3] if len(pixel) == 3 or pixel[3] == 255 else background
                    row.append((*rgb, alpha))
                rows.append(row)
            write_png(assets / asset_name(variant, size), rows)


if __name__ == "__main__":
    generate()

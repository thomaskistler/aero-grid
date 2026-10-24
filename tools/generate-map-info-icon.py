# SPDX-License-Identifier: GPL-2.0-only
"""Render the map's original circled information glyph at native size."""
import argparse
from pathlib import Path

from PIL import Image, ImageDraw


def render():
    scale = 4
    image = Image.new("RGBA", (24 * scale, 24 * scale))
    draw = ImageDraw.Draw(image)
    draw.ellipse((8, 8, 87, 87), outline="white", width=6)
    draw.ellipse((44, 25, 51, 32), fill="white")
    draw.rounded_rectangle((45, 41, 50, 68), radius=3, fill="white")
    return image.resize((24, 24), Image.Resampling.LANCZOS)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    render().save(args.output)

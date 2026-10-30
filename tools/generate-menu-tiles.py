# SPDX-License-Identifier: GPL-2.0-only
"""Reproduce the official EdgeTX v2.12 QuickMenu's monochrome tile icons.

QuickMenu and QuickMenuGroup (radio/src/gui/colorlcd/setup_menus/) are not
exported by radio/src/lua/api_colorlcd_lvgl.cpp: lvgl.menu wraps the list-style
LvglWidgetMenu instead. AeroGrid uses box/rectangle/image/label and its own
deferred event routing, avoiding unsupported focus styles or native dialogs.

Artwork: EdgeTX v2.12.0 GPL-2.0-only masks, radio/src/bitmaps/<display>/
default_theme/mask_menu_{model,theme}.png. Their inverse grayscale is the exact
alpha used by EdgeTX's encode-bitmap.py. Both foreground colors are pre-rendered
because Lua's image primitive exposes no recoloring API. The pilot-wings
silhouette and palette generator are deliberately untouched.
"""
import importlib.util
from pathlib import Path
import urllib.request
import subprocess

ROOT = Path(__file__).resolve().parents[1]
SOURCE = "https://raw.githubusercontent.com/EdgeTX/edgetx/v2.12.0/radio/src/bitmaps"
DISPLAYS = {"320x240": 36, "480x272": 45, "800x480": 62}
ICONS = ("model", "theme")

spec = importlib.util.spec_from_file_location("header_icons", ROOT / "tools/generate-menu-icon.py")
png = importlib.util.module_from_spec(spec)
spec.loader.exec_module(png)


def generate():
    output = ROOT / "build/menu-tiles"
    output.mkdir(parents=True, exist_ok=True)
    assets = ROOT / "src/WIDGETS/AeroGrid/assets"
    for display, size in DISPLAYS.items():
        scale = size / 45
        width, height = (int(value * scale + 0.5) for value in (122, 25))
        subprocess.run(["sips", "-s", "format", "png", "-z", str(height), str(width),
                        str(assets / "menu-title.svg"), "--out", str(assets / f"menu-title-{size}.png")],
                       check=True, stdout=subprocess.DEVNULL)
        for icon in ICONS:
            path = output / f"{display}-{icon}.png"
            urllib.request.urlretrieve(f"{SOURCE}/{display}/default_theme/mask_menu_{icon}.png", path)
            rows = png.read_png(path)
            for name, foreground in (("black", 0), ("white", 255)):
                png.write_png(assets / f"menu-{icon}-{name}-{size}.png", [
                    [(foreground, foreground, foreground, 255 - pixel[0]) for pixel in row] for row in rows
                ])


if __name__ == "__main__":
    generate()

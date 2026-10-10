# SPDX-License-Identifier: GPL-2.0-only
"""Capture panel recipes through the native macOS/Companion TX16S simulator."""
import argparse
import hashlib
import json
from pathlib import Path
import platform
import shutil
import struct
import subprocess
import zlib
from capture_recipes import (PANELS, RECIPE_DIR, configure_model, config_yaml,
                            fixture_inputs, load_recipe, readiness)


ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "build/doc-capture"

def placements(recipe):
    return {name: tuple(panel[key] for key in ("col", "row", "colSpan", "rowSpan"))
            for name, panel in recipe["panels"].items()}


def png(path, rgb, width, height):
    def chunk(kind, payload):
        return (struct.pack(">I", len(payload)) + kind + payload
                + struct.pack(">I", zlib.crc32(kind + payload)))
    rows = b"".join(b"\0" + rgb[y * width * 3:(y + 1) * width * 3] for y in range(height))
    path.write_bytes(b"\x89PNG\r\n\x1a\n"
                     + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
                     + chunk(b"IDAT", zlib.compress(rows))
                     + chunk(b"IEND", b""))


def rect(col, row, cols, rows):
    def axis(size, start, span):
        available = size - 12
        first = start * available // 4 + start * 4
        last = (start + span) * available // 4 + (start + span - 1) * 4
        return first, last - first
    x, width = axis(480, col, cols)
    y, height = axis(272, row, rows)
    return x, y, width, height


def model_image(path):
    # Original procedural aircraft silhouette, not the fixture's third-party bitmap.
    width, height = 192, 96
    pixels = bytearray()
    for y in range(height):
        for x in range(width):
            dx, dy = abs(x - width // 2), y
            body = dx <= 5 and 12 <= dy <= 83
            wings = 36 <= dy <= 57 and dx <= 72 - abs(dy - 47) * 3
            tail = 70 <= dy <= 81 and dx <= 28 - abs(dy - 76) * 3
            pixels.extend((90, 211, 239) if body or wings or tail else (33, 42, 49))
    png(path, pixels, width, height)


def prepare(sd, recipe, recipe_path=None):
    panel = recipe["panel"]
    sd.mkdir()
    shutil.copytree(ROOT / "tests/fixtures/sdcard", sd, dirs_exist_ok=True)
    widget = sd / "WIDGETS/AeroGrid"
    shutil.copytree(ROOT / "src/WIDGETS/AeroGrid", widget)
    for bytecode in sd.rglob("*.luac"):
        bytecode.unlink()
    # The Layout option is a CHOICE stored as a 1-based registry position.
    registry = sd / "AEROGRID/registry.txt"
    names = registry.read_text().split()
    if "capture-panels" not in names:
        names.append("capture-panels")
        registry.write_text("\n".join(names) + "\n")
    position = names.index("capture-panels") + 1
    model = sd / "MODELS/model1.yml"
    text = model.read_text()
    prefix, rest = text.split("screenData:", 1)
    _, suffix = rest.split("view:", 1)
    prefix = configure_model(prefix, recipe)
    if panel == "model-identity":
        if "bitmap" in recipe["sample"]:
            path = recipe_path or RECIPE_DIR / f"{panel}.yaml"
            bitmap = path.resolve().parent / recipe["sample"]["bitmap"]
            shutil.copyfile(bitmap, sd / "IMAGES" / bitmap.name)
        else:
            model_image(sd / "IMAGES/agplane.png")
    model.write_text(prefix + """screenData:
   0:
      LayoutId: Layout1x1AM
      layoutData:
         zones:
            0:
               widgetName: AeroGrid
               widgetData:
                  options:
                     0:
                        type: Unsigned
                        value:
                           unsignedValue: POSITION
                     1:
                        type: Unsigned
                        value:
                           unsignedValue: THEME
view: 0
""".replace("THEME", str(["modern", "modern-light"].index(recipe["theme"]) + 1))
                     .replace("POSITION", str(position))
                     + suffix.split("\n", 1)[1])
    layout = f"version: 1\ntheme:\n  mode: {recipe['theme']}\ngrid:\n  columns: 4\n  rows: 4\npanels:\n"
    for name, (col, row, cols, rows) in placements(recipe).items():
        layout += (f"  - id: subject-{name}\n    type: {panel}\n"
                   f"    col: {col}\n    row: {row}\n    colSpan: {cols}\n    rowSpan: {rows}\n"
                   "    config:\n" + config_yaml(recipe["config"]))
    (widget / "layouts/capture-panels.yaml").write_text(layout)
    main = widget / "main.lua"
    source = main.read_text()
    if recipe.get("brighten_supporting_text", False):
        theme_setup = "        context.theme = context.themeBuilder.build(themeConfig.mode or context.themeMode, themeConfig.overrides)"
        if source.count(theme_setup) != 1:
            raise RuntimeError("Theme setup changed; update capture instrumentation explicitly.")
        source = source.replace(theme_setup, theme_setup + """
        context.theme.rgb.textFaint = context.theme.rgb.textMuted
        context.theme.color.textFaint = context.theme.color.textMuted
""")
    inputs = fixture_inputs(recipe)
    if inputs:
        (widget / "capture-inputs.lua").write_text(inputs)
        if source.count("support.environment()") != 1:
            raise RuntimeError("Service environment setup changed; update capture instrumentation explicitly.")
        source = source.replace("support.environment()",
                                'support.environment(assert(loadScript("/WIDGETS/AeroGrid/capture-inputs.lua"))())')
    source = """local function captureEqual(actual, expected)
    if type(expected) ~= "table" then return actual == expected end
    if type(actual) ~= "table" then return false end
    for key, value in pairs(expected) do
        if not captureEqual(actual[key], value) then return false end
    end
    return true
end
""" + source
    if source.count("    refresh = refresh,") != 1:
        raise RuntimeError("Widget refresh export changed; update capture instrumentation explicitly.")
    # Readiness observes real services consuming firmware or isolated synthetic inputs.
    source = source.replace("    refresh = refresh,", """    refresh = function(context)
        refresh(context)
        if #context.errors > 0 then error(table.concat(context.errors, "\\n")) end
        if context.stage or #context.panels ~= PANEL_COUNT then return end
        for _, entry in ipairs(context.panels) do
""".replace("PANEL_COUNT", str(len(recipe["panels"]))) + ("""
            local instance = entry.instance
            if instance.bar then
                instance.showVisual = false
                lvgl.hide(instance.bar.track)
                lvgl.hide(instance.bar.fill)
            end
""" if recipe.get("hide_bottom_bar", False) else "") + readiness(recipe) + """
            if entry.instance.stateName == "unavailable" or entry.instance.stateName == "stale" then return end
            if entry.instance.text == "--" or entry.instance.text == "--:--" then return end
        end
        if not context.captureReady then
            local file = assert(io.open("/capture-ready.txt", "w"))
            io.write(file, "recipe values verified")
            io.close(file)
            context.captureReady = true
        end
    end,""")
    main.write_text(source)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    selection = parser.add_mutually_exclusive_group(required=True)
    selection.add_argument("--panel", choices=PANELS)
    selection.add_argument("--recipe", type=Path, help="Path to a named YAML capture recipe")
    selection.add_argument("--all", action="store_true")
    parser.add_argument("--companion", type=Path, default=Path("/Applications/EdgeTX Companion 2.12.app"))
    args = parser.parse_args()
    paths = (sorted(RECIPE_DIR.glob("*.yaml")) if args.all else
             [args.recipe or RECIPE_DIR / f"{args.panel}.yaml"])
    if not paths:
        parser.error(f"No YAML recipes found in {RECIPE_DIR}")
    try:
        recipes = [(path, load_recipe(path)) for path in paths]
    except (ValueError, OSError) as error:
        parser.error(str(error))
    if platform.system() != "Darwin":
        parser.error("This native capture proof currently requires macOS.")
    library = args.companion / "Contents/Resources/libedgetx-tx16s-simulator.dylib"
    frameworks = args.companion / "Contents/Frameworks"
    if not library.is_file():
        parser.error(f"Simulator library not found: {library}")
    OUTPUT.mkdir(parents=True, exist_ok=True)
    executable = OUTPUT / "capture-native"
    architecture = subprocess.check_output(["lipo", "-archs", str(library)], text=True).strip().split()
    if len(architecture) != 1:
        parser.error("Select a single-architecture simulator library for this prototype.")
    subprocess.run(["clang++", "-std=c++11", "-arch", architecture[0],
                    str(ROOT / "tools/capture-native.cpp"), f"-Wl,-rpath,{frameworks}",
                    "-o", str(executable)], check=True)
    panels = [recipe["panel"] for _, recipe in recipes]
    if len(set(panels)) != len(panels):
        parser.error("Select at most one recipe per panel type in each invocation.")
    for path, recipe in recipes:
        capture(recipe, path, executable, library)


def capture(recipe, recipe_path, executable, library):
    panel = recipe["panel"]
    spans = placements(recipe)
    border = recipe["border"]["pixels"]
    color = recipe["border"]["rgb"]
    if panel not in PANELS:
        raise ValueError(f"Unsupported panel output: {panel}")
    directory = OUTPUT / panel
    if directory.is_symlink():
        raise RuntimeError(f"Capture output must not be a symlink: {directory}")
    if directory.exists():
        shutil.rmtree(directory)
    directory.mkdir()
    sd = directory / "sdcard"
    prepare(sd, recipe, recipe_path)
    (directory / "recipe.yaml").write_text(recipe_path.read_text())
    regions = directory / "regions.txt"
    regions.write_text("".join(" ".join(map(str, rect(*placement))) + "\n"
                               for placement in spans.values()))
    raw = directory / "frame.rgb565"
    with (directory / "simulator.log").open("w") as log:
        try:
            subprocess.run([str(executable), str(library), str(sd), str(raw), str(regions)],
                           stdout=log, stderr=subprocess.STDOUT, check=True, timeout=45)
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
            raise RuntimeError(f"Capture failed; inspect {directory / 'simulator.log'}") from error
    pixels = raw.read_bytes()
    if len(pixels) != 480 * 272 * 2:
        raise RuntimeError("Unexpected framebuffer size")
    rgb = bytearray()
    for (pixel,) in struct.iter_unpack("<H", pixels):
        rgb.extend(((pixel >> 11) * 255 // 31, ((pixel >> 5) & 63) * 255 // 63,
                    (pixel & 31) * 255 // 31))
    png(directory / "full-frame.png", rgb, 480, 272)
    crops = {}
    for name, placement in spans.items():
        x, y, width, height = rect(*placement)
        crop = b"".join(rgb[((y + i) * 480 + x) * 3:((y + i) * 480 + x + width) * 3]
                        for i in range(height))
        output_width, output_height = width + border * 2, height + border * 2
        bordered = bytearray(bytes(color) * (output_width * output_height))
        for i in range(height):
            offset = ((i + border) * output_width + border) * 3
            bordered[offset:offset + width * 3] = crop[i * width * 3:(i + 1) * width * 3]
        png(directory / f"{name}.png", bordered, output_width, output_height)
        crops[name] = {"placement": placement, "crop": [x, y, width, height],
                       "border_px": border, "border_rgb": color,
                       "output_size": [output_width, output_height]}
    provenance = {"library": str(library), "sha256": hashlib.sha256(library.read_bytes()).hexdigest(),
                  "revision": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
                  "source_sha256": {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
                                    for path in sorted((ROOT / "src/WIDGETS/AeroGrid").rglob("*"))
                                    if path.is_file() and path.suffix in {".lua", ".yaml"}},
                  "capture_sha256": {path.name: hashlib.sha256(path.read_bytes()).hexdigest()
                                     for path in (Path(__file__), ROOT / "tools/capture_recipes.py",
                                                  ROOT / "tools/capture-native.cpp")},
                  "theme": recipe["theme"], "panel": panel,
                  "sample_data": ("synthetic firmware API inputs; real services and EdgeTX rendering"
                                  if fixture_inputs(recipe) else "isolated firmware model settings"),
                  "recipe": recipe, "recipe_path": str(recipe_path),
                  "captures": crops}
    if panel == "model-identity" and "bitmap" in recipe["sample"]:
        bitmap = recipe_path.resolve().parent / recipe["sample"]["bitmap"]
        provenance["bitmap"] = {"path": recipe["sample"]["bitmap"],
                                "sha256": hashlib.sha256(bitmap.read_bytes()).hexdigest()}
    (directory / "provenance.json").write_text(json.dumps(provenance, indent=2) + "\n")
    print(f"Verified {panel} captures: {directory}")
    return directory


if __name__ == "__main__":
    main()

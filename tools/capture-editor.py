# SPDX-License-Identifier: GPL-2.0-only
"""Capture the real editor UI in the native macOS EdgeTX TX16S simulator."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import struct
import subprocess
import zlib

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "build/editor-capture"
SCENES = ("overview", "settings", "metric-entry", "exit", "save-as")

LAYOUT = """version: 1
grid:
  columns: 4
  rows: 4
panels:
  - id: reading
    type: metric
    col: 0
    row: 0
    colSpan: 2
    rowSpan: 2
    config:
      metrics:
        - source: gvar1
          label: Reading
  - id: timer
    type: flight-timer
    col: 2
    row: 0
    colSpan: 2
    rowSpan: 1
    config:
      timer: 0
"""


def prepare(sd, scene):
    shutil.copytree(ROOT / "tests/fixtures/sdcard", sd)
    shutil.copytree(ROOT / "src/WIDGETS/AeroGrid", sd / "WIDGETS/AeroGrid")
    radio = sd / "RADIO/radio.yml"
    radio.write_text(radio.read_text().replace('currModelFilename: "model2.yml"',
                                              'currModelFilename: "model4.yml"'))
    (sd / "WIDGETS/AeroGrid/layouts/default.yaml").write_text(LAYOUT)
    main = sd / "WIDGETS/AeroGrid/main.lua"
    source = main.read_text()
    needle = "    refresh = refresh,"
    if source.count(needle) != 1:
        raise RuntimeError("Widget refresh export changed; update capture instrumentation.")
    # Only the isolated copy is instrumented. Fullscreen is entered with a real
    # simulator long-press; these commands open the production editor/dialogs.
    source = source.replace(needle, """
    refresh = function(context, widgetEvent, touchState)
        refresh(context, widgetEvent, touchState)
        if #context.errors > 0 then error(table.concat(context.errors, "\\n")) end
        if not isFullScreen() or context.stage or context.reloadState then return end
        context.captureTicks = (context.captureTicks or 0) + 1
        if context.captureTicks < 12 then return end
        if not context.editorUi then
            assert(openEditor(context), "capture could not open editor")
            return
        end
        local state = context.editorUi
        if state.buildStage or state.previewPending or state.previewRefresh
            or state.drawerBuild or state.drawerPending then return end
        if not context.captureSceneOpened then
            state.session.selected = 1
            local scene = "SCENE"
            if scene == "settings" then
                context.editorDrawerModule.open(context, state, "configure")
            elseif scene == "metric-entry" then
                context.editorDrawerModule.open(context, state, "configure", "metrics", 1)
            elseif scene == "exit" then
                state.session.dirty = true
                context.editorDrawerModule.openExit(context, state)
            elseif scene == "save-as" then
                context.editorDrawerModule.openName(context, state, "Sonic1")
            end
            context.captureSceneOpened = true
            context.captureSettled = 0
            return
        end
        context.captureSettled = context.captureSettled + 1
        if context.captureSettled < 15 or context.captureReady then return end
        local file = assert(io.open("/capture-ready.txt", "w"))
        io.write(file, "production editor scene ready")
        io.close(file)
        context.captureReady = true
    end,
""".replace("SCENE", scene))
    main.write_text(source)


def write_png(path, frame):
    rgb = bytearray()
    for (pixel,) in struct.iter_unpack("<H", frame):
        rgb.extend(((pixel >> 11) * 255 // 31, ((pixel >> 5) & 63) * 255 // 63,
                    (pixel & 31) * 255 // 31))
    def chunk(kind, data):
        return (struct.pack(">I", len(data)) + kind + data
                + struct.pack(">I", zlib.crc32(kind + data)))
    rows = b"".join(b"\0" + rgb[y * 480 * 3:(y + 1) * 480 * 3] for y in range(272))
    path.write_bytes(b"\x89PNG\r\n\x1a\n"
                     + chunk(b"IHDR", struct.pack(">IIBBBBB", 480, 272, 8, 2, 0, 0, 0))
                     + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--companion", type=Path, default=Path("/Applications/EdgeTX Companion 2.12.app"))
    args = parser.parse_args()
    library = args.companion / "Contents/Resources/libedgetx-tx16s-simulator.dylib"
    if not library.is_file():
        parser.error(f"Simulator library not found: {library}")
    architecture = subprocess.check_output(["lipo", "-archs", str(library)], text=True).split()
    if len(architecture) != 1:
        parser.error("A single-architecture simulator library is required.")
    OUTPUT.mkdir(parents=True, exist_ok=True)
    executable = OUTPUT / "capture-native"
    subprocess.run(["clang++", "-std=c++11", "-arch", architecture[0],
                    str(ROOT / "tools/capture-native.cpp"),
                    f"-Wl,-rpath,{args.companion / 'Contents/Frameworks'}",
                    "-o", str(executable)], check=True)
    for scene in SCENES:
        directory = OUTPUT / scene
        if directory.is_symlink():
            raise RuntimeError(f"Capture directory must not be a symlink: {directory}")
        if directory.exists():
            shutil.rmtree(directory)
        directory.mkdir()
        sd = directory / "sdcard"
        prepare(sd, scene)
        regions = directory / "regions.txt"
        regions.write_text("0 0 480 272\n")
        frame = directory / "frame.rgb565"
        with (directory / "simulator.log").open("w") as log:
            try:
                subprocess.run([str(executable), str(library), str(sd), str(frame),
                                str(regions), "fullscreen"], stdout=log,
                               stderr=subprocess.STDOUT, check=True, timeout=45)
            except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
                raise RuntimeError(f"Capture failed; inspect {directory / 'simulator.log'}") from error
        pixels = frame.read_bytes()
        if len(pixels) != 480 * 272 * 2:
            raise RuntimeError("Unexpected framebuffer size")
        write_png(directory / f"{scene}.png", pixels)
        print(directory / f"{scene}.png")
    (OUTPUT / "provenance.json").write_text(json.dumps({
        "revision": subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip(),
        "simulator": str(library),
        "simulator_sha256": hashlib.sha256(library.read_bytes()).hexdigest(),
        "source_sha256": {
            str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in sorted((ROOT / "src/WIDGETS/AeroGrid").rglob("*"))
            if path.is_file()
        },
        "method": "Native TX16S framebuffer; isolated sample layout and editor command automation.",
        "scenes": SCENES,
    }, indent=2) + "\n")


if __name__ == "__main__":
    main()

# SPDX-License-Identifier: GPL-2.0-only
"""Capture dashboards and editor UI in the native macOS EdgeTX TX16S simulator."""
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
SCENES = ("overview", "settings", "state-settings", "metric-entry", "exit", "save-as")
THEME_SCENES = ("theme-modern-dark", "theme-modern-light", "theme-custom")
DASHBOARD_SCENES = ("dashboard",)
DASHBOARD_INPUTS = """model.setGlobalVariable(8, 0, 42)
model.setGlobalVariable(0, 0, 30)
assert(model.getGlobalVariable(8, 0) == 42, "capture could not initialize GV9")
assert(model.getGlobalVariable(0, 0) == 30, "capture could not initialize GV1")
local sources = {
    { name = "RxBt", id = 30000, unit = 1, prec = 2, value = 8.12 },
    { name = "RQly", id = 30001, unit = 13, prec = 0, value = 98 },
    { name = "1RSS", id = 30002, unit = 29, prec = 0, value = -87 },
    { name = "RFMD", id = 30003, unit = 0, prec = 0, value = 6 },
    { name = "Alt", id = 30004, unit = 9, prec = 1, value = 128.4 },
    { name = "Alt+", id = 30005, unit = 9, prec = 1, value = 176.2 },
    { name = "VSpd", id = 30006, unit = 5, prec = 1, value = 2.4 },
    { name = "VSpd+", id = 30007, unit = 5, prec = 1, value = 3.6 },
}
local disarmed = assert(getSwitchIndex("SF" .. CHAR_UP))
local armed = assert(getSwitchIndex("SF" .. CHAR_DOWN))
return {
    getFieldInfo = function(name)
        for _, source in ipairs(sources) do
            if source.name == name then return source end
        end
        return getFieldInfo(name)
    end,
    getValue = function(id)
        if id == "tx-voltage" then return 8.1 end
        for _, source in ipairs(sources) do
            if source.id == id or source.name == id then return source.value end
        end
        return getValue(id)
    end,
    getSwitchValue = function(id)
        if id == disarmed then return true end
        if id == armed then return false end
        return getSwitchValue(id)
    end,
    getRSSI = function() return 85 end,
    model = {
        getInfo = model.getInfo,
        getTimer = model.getTimer,
        getGlobalVariable = model.getGlobalVariable,
        setGlobalVariable = model.setGlobalVariable,
        getGlobalVariableDetails = model.getGlobalVariableDetails,
        getSensor = function(index) return sources[index + 1] end,
    },
}
"""
SETUP_SCENES = {
    "screen-menu": [(500, 20, 20, 1), (520, 20, 20, 0)],
    "screens": [(500, 20, 20, 1), (520, 20, 20, 0),
                (650, 395, 98, 1), (670, 395, 98, 0)],
}
SETUP_SCENES["add-screen"] = SETUP_SCENES["screens"] + [
    (800, 130, 22, 1), (820, 130, 22, 0)]
SETUP_SCENES["new-screen"] = SETUP_SCENES["add-screen"] + [
    (950, 240, 158, 1), (970, 240, 158, 0)]
SETUP_SCENES["screen-layout"] = SETUP_SCENES["new-screen"] + [
    (1100, 225, 95, 1), (1120, 225, 95, 0)]
# Reopen after choosing App mode so the chooser highlights the recommended row.
SETUP_SCENES["app-mode-choice"] = SETUP_SCENES["screen-layout"] + [
    (1250, 230, 52, 1), (1270, 230, 52, 0),
    (1400, 225, 95, 1), (1420, 225, 95, 0)]
SETUP_SCENES["app-screen"] = SETUP_SCENES["screen-layout"] + [
    (1250, 230, 52, 1), (1270, 230, 52, 0)]
SETUP_SCENES["setup-widgets"] = SETUP_SCENES["app-screen"] + [
    (1400, 345, 95, 1), (1420, 345, 95, 0)]
SETUP_SCENES["select-widget"] = SETUP_SCENES["setup-widgets"] + [
    (1550, 220, 130, 1), (1570, 220, 130, 0)]
SETUP_SCENES["widget-options"] = SETUP_SCENES["select-widget"] + [
    (1700, 215, 60, 1), (1720, 215, 60, 0)]
SETUP_SCENES["select-layout"] = SETUP_SCENES["widget-options"] + [
    (1850, 277, 133, 1), (1870, 277, 133, 0)]

LAYOUT = """version: 2
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

STATE_LAYOUT = """version: 2
grid:
  columns: 4
  rows: 4
panels:
  - id: labels
    type: state
    col: 0
    row: 0
    colSpan: 2
    rowSpan: 2
    config:
      entries:
        - label: MODE
          states:
            - switch: SA^
              text: UP
            - switch: SA-
              text: MID
            - switch: SAv
              text: DOWN
        - label: GEAR
          states:
            - switch: SB^
              text: UP
            - switch: SBv
              text: DOWN
"""


def prepare(sd, scene):
    shutil.copytree(ROOT / "tests/fixtures/sdcard", sd)
    shutil.copytree(ROOT / "src/WIDGETS/AeroGrid", sd / "WIDGETS/AeroGrid")
    shutil.copytree(
        ROOT / "tests/fixtures/layouts/development",
        sd / "WIDGETS/AeroGrid/layouts",
        dirs_exist_ok=True,
    )
    # Keep capture scenes independent of the development model's extra screens.
    (sd / "MODELS/model1.yml").write_text("""semver: 3.0.0
header:
   name: "AEROGRID SHOT"
   bitmap: ""
   labels: ""
disableThrottleWarning: 1
screenData:
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
                           unsignedValue: 2
                     1:
                        type: Unsigned
                        value:
                           unsignedValue: THEME
""".replace("THEME", {"theme-modern-light": "2", "theme-custom": "3"}.get(scene, "1")))
    if scene in DASHBOARD_SCENES:
        model = sd / "MODELS/model1.yml"
        model.write_text(model.read_text().replace('name: "AEROGRID SHOT"', 'name: "Crack Yak"')
                         .replace('bitmap: ""', 'bitmap: "crackyak.png"') + """timers:
   0:
      start: 600
      value: 347
      mode: OFF
      persistent: 1
      name: "Flight"
""")
        shutil.copyfile(ROOT / "tools/capture-assets/crackyak.png", sd / "IMAGES/crackyak.png")
        widget = sd / "WIDGETS/AeroGrid"
        (widget / "capture-inputs.lua").write_text(DASHBOARD_INPUTS)
        loader = widget / "lib/dashboard_loader.lua"
        loader_source = loader.read_text()
        if loader_source.count("support.environment()") != 1:
            raise RuntimeError("Service environment setup changed; update capture instrumentation.")
        loader.write_text(loader_source.replace(
            "support.environment()",
            'support.environment(assert(loadScript("/WIDGETS/AeroGrid/capture-inputs.lua"))())',
        ))
    if scene in SETUP_SCENES:
        # Show only the layouts included in the installation ZIP, not the
        # development fixture's review and diagnostic screens.
        for layout in (sd / "WIDGETS/AeroGrid/layouts").glob("*.yaml"):
            if layout.stem not in ("Empty", "Default", "Diagnostics", "Palette"):
                layout.unlink()
        (sd / "AEROGRID/layout-registry.txt").write_text("Empty\nDefault\nHost\nTheme\n")
        (sd / "capture-ready.txt").write_text("native setup capture")
        return
    if scene in THEME_SCENES:
        layout = (ROOT / "src/WIDGETS/AeroGrid/layouts/Palette.yaml").read_text()
        mode = scene.removeprefix("theme-")
        if mode == "custom":
            source = sd / "WIDGETS/AeroGrid/themes/modern-dark.yml"
            custom = source.read_text()
            custom = custom.replace("name: modern-dark\n", "name: custom\n", 1)
            custom = custom.replace("label: Modern Dark\n", "label: Custom\n", 1)
            custom = custom.replace("accent: cyan\n", "accent: green\n", 1)
            custom = custom.replace("correctForContrast: false\n", "correctForContrast: true\n", 1)
            custom = custom.replace("canvas: 0x0A0C0E", "canvas: 0x101820", 1)
            custom = custom.replace("surface: 0x212830", "surface: 0x304050", 1)
            custom = custom.replace("text: 0xF4F6F7", "text: 0xFFF4DF", 1)
            user_themes = sd / "AEROGRID/themes"
            user_themes.mkdir(parents=True, exist_ok=True)
            (user_themes / "custom.yml").write_text(custom)
            (sd / "AEROGRID/theme-registry.txt").write_text("modern-dark\nmodern-light\ncustom\n")
    elif scene in DASHBOARD_SCENES:
        layout = (ROOT / "src/WIDGETS/AeroGrid/layouts/Default.yaml").read_text()
    else:
        layout = STATE_LAYOUT if scene == "state-settings" else LAYOUT
    if scene == "settings":
        layout = layout.replace("        - source: gvar1\n          label: Reading", """        - source: Alt
          label: Altitude
          unit: m
        - source: GSpd
          label: Speed
          unit: km/h""")
    (sd / "WIDGETS/AeroGrid/layouts/Default.yaml").write_text(layout)
    main = sd / "WIDGETS/AeroGrid/main.lua"
    source = main.read_text()
    needle = "    refresh = refresh,"
    if source.count(needle) != 1:
        raise RuntimeError("Widget refresh export changed; update capture instrumentation.")
    if scene in DASHBOARD_SCENES:
        source = source.replace(needle, """
    refresh = function(context, widgetEvent, touchState)
        refresh(context, widgetEvent, touchState)
        if #context.errors > 0 then error(table.concat(context.errors, "\\n")) end
        if not isFullScreen() or context.stage or context.reloadState or context.captureReady then return end
        if #context.panels ~= 9 then return end
        local expected = {
            ["receiver-battery"] = "4.06", ["link"] = "98",
            ["transmitter-battery"] = "8.1", ["altitude"] = "128.4",
            ["flight-clock"] = "5:47", ["flight-count"] = "42",
            ["expo"] = "30", ["mode"] = "DISARMED",
        }
        for _, entry in ipairs(context.panels) do
            local instance = entry.instance
            if not instance or instance.stateName == "unavailable" or instance.stateName == "stale" then return end
            local text = expected[entry.placement.id]
            assert(text or entry.placement.id == "identity", "Default layout changed; update capture checks")
            if text and instance.text ~= text then return end
            if entry.placement.id == "identity" then
                if not instance.image or not instance.feed.available or instance.feed.name ~= "Crack Yak" then return end
            end
        end
        local file = assert(io.open("/capture-ready.txt", "w"))
        io.write(file, "production Default dashboard and sample readings verified")
        io.close(file)
        context.captureReady = true
    end,
""")
        main.write_text(source)
        return
    if scene in THEME_SCENES:
        source = source.replace(needle, """
    refresh = function(context, widgetEvent, touchState)
        refresh(context, widgetEvent, touchState)
        if #context.errors > 0 then error(table.concat(context.errors, "\\n")) end
        if not isFullScreen() or context.stage or context.reloadState or context.captureReady then return end
        assert(#context.panels == 1 and context.panels[1].instance, "theme showcase not loaded")
        assert(context.theme.mode == "EXPECTED", "unexpected showcase theme")
        local file = assert(io.open("/capture-ready.txt", "w"))
        io.write(file, "production theme showcase ready")
        io.close(file)
        context.captureReady = true
    end,
""".replace("EXPECTED", mode))
        main.write_text(source)
        return
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
            assert(context.editorController.openEditor(context), "capture could not open editor")
            return
        end
        local state = context.editorUi
        if state.buildStage or state.previewPending or state.previewRefresh
            or state.drawerBuild or state.drawerPending then return end
        if not context.captureSceneOpened then
            state.session.selected = 1
            local scene = "SCENE"
            if scene == "settings" or scene == "state-settings" then
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
    parser.add_argument("--scene", choices=SCENES + tuple(SETUP_SCENES) + THEME_SCENES + DASHBOARD_SCENES)
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
    for scene in (args.scene,) if args.scene else SCENES + tuple(SETUP_SCENES):
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
        mode = "fullscreen"
        if scene in SETUP_SCENES:
            actions = directory / "actions.txt"
            actions.write_text("".join(" ".join(map(str, action)) + "\n"
                                      for action in SETUP_SCENES[scene]))
            mode = "actions=" + str(actions)
        with (directory / "simulator.log").open("w") as log:
            try:
                subprocess.run([str(executable), str(library), str(sd), str(frame),
                                str(regions), mode], stdout=log,
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
        "capture_sha256": {
            path.name: hashlib.sha256(path.read_bytes()).hexdigest()
            for path in (Path(__file__), ROOT / "tools/capture-native.cpp")
        },
        "dashboard_sample": ({
            "layout": "src/WIDGETS/AeroGrid/layouts/Default.yaml",
            "inputs": DASHBOARD_INPUTS,
            "timer_remaining_seconds": 347,
            "timer_start_seconds": 600,
            "model": "Crack Yak",
            "bitmap": "tools/capture-assets/crackyak.png",
            "bitmap_sha256": hashlib.sha256(
                (ROOT / "tools/capture-assets/crackyak.png").read_bytes()).hexdigest(),
            "disclosure": "Synthetic telemetry, TX voltage, and switch inputs through real services; "
                          "isolated firmware timer and global variables; unmodified production layout and theme.",
        } if args.scene in DASHBOARD_SCENES else None),
        "method": ("Native TX16S framebuffer; fullscreen production Default dashboard with isolated sample inputs."
                   if args.scene in DASHBOARD_SCENES else
                   "Native TX16S framebuffer; isolated sample layouts and editor command automation."),
        "scenes": (args.scene,) if args.scene else SCENES + tuple(SETUP_SCENES),
    }, indent=2) + "\n")


if __name__ == "__main__":
    main()

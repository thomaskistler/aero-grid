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
SCENES = ("overview", "settings", "state-settings", "state-entry", "state-condition", "metric-entry", "exit", "save-as", "navigation-tape",
          "navigation-location")
# Configuration drawers captured as full-height images rather than one screen.
# Settings drawers of the remaining panels, one per panel page.
PANEL_DRAWER_CONFIG = {
    "host-diagnostics": {"label": "Host", "section": "identity"},
    "service-probe": {"service": "telemetry", "source": "RxBt", "label": "Probe"},
}
PANEL_DRAWER_KINDS = ("flight-counter", "flight-mode", "flight-timer", "host-diagnostics", "link-status",
                      "model-identity", "navigation", "output", "rx-battery", "service-probe", "trim-panel",
                      "tx-battery")
PANEL_SETTINGS_SCENES = tuple(f"{kind}-settings" for kind in PANEL_DRAWER_KINDS)
SCENES = SCENES + PANEL_SETTINGS_SCENES
STITCHED_SCENES = ("settings", "state-settings", "state-entry", "state-condition", "metric-entry") + PANEL_SETTINGS_SCENES
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

LAYOUT = """version: 3
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


def prepare(sd, scene, shift=0):
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
    elif scene in PANEL_SETTINGS_SCENES:
        from capture_recipes import config_yaml, load_recipe
        kind = scene.removesuffix("-settings")
        recipe = ROOT / f"tools/capture-recipes/{kind}.yaml"
        config = PANEL_DRAWER_CONFIG.get(kind) or load_recipe(recipe)["config"]
        layout = f"""version: 3
grid:
  columns: 4
  rows: 4
panels:
  - id: panel
    type: {kind}
    col: 0
    row: 0
    colSpan: 2
    rowSpan: 2
    config:
{config_yaml(config)}"""
    else:
        layout = STATE_LAYOUT if scene.startswith("state-") else LAYOUT
    if scene in ("navigation-tape", "navigation-location"):
        layout = """version: 3
grid:
  columns: 4
  rows: 4
panels:
  - id: nav
    type: navigation
    col: 0
    row: 0
    colSpan: 2
    rowSpan: 2
    config:
      source: GPS
"""
        from capture_recipes import fixture_inputs, load_recipe
        recipe = load_recipe(ROOT / "tools/capture-recipes/navigation.yaml")
        widget = sd / "WIDGETS/AeroGrid"
        (widget / "capture-inputs.lua").write_text(fixture_inputs(recipe))
        loader = widget / "lib/dashboard_loader.lua"
        loader.write_text(loader.read_text().replace(
            "support.environment()",
            'support.environment(assert(loadScript("/WIDGETS/AeroGrid/capture-inputs.lua"))())',
        ))
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
    if scene == "navigation-location":
        source = source.replace(needle, """
    refresh = function(context, widgetEvent, touchState)
        refresh(context, widgetEvent, touchState)
        if #context.errors > 0 then error(table.concat(context.errors, "\\n")) end
        if context.captureReady then return end
        if not context.locationDetails then
            context.capturePreviousLocation = nil
            return
        end
        local details = context.locationDetails
        assert(isFullScreen() and details.valid and details.code, "location QR not displayed")
        assert(not context.editorUi, "navigation tap opened editing")
        if details ~= context.capturePreviousLocation then
            context.captureLocationOpens = (context.captureLocationOpens or 0) + 1
            context.capturePreviousLocation = details
        end
        if context.captureLocationOpens < 3 then return end
        local file = assert(io.open("/capture-ready.txt", "w"))
        io.write(file, details.url)
        io.close(file)
        context.captureReady = true
    end,
""")
        main.write_text(source)
        return
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
            if scene == "settings" or string.sub(scene, -9) == "-settings" or scene == "navigation-tape" then
                context.editorDrawerModule.open(context, state, "configure")
            elseif scene == "metric-entry" then
                context.editorDrawerModule.open(context, state, "configure", "metrics", 1)
            elseif scene == "state-entry" then
                context.editorDrawerModule.open(context, state, "configure", "entries", 1)
            elseif scene == "state-condition" then
                context.editorDrawerModule.open(context, state, "configure", "entries", nil, { 1, "states", 1 })
            elseif scene == "exit" then
                state.session.dirty = true
                context.editorDrawerModule.openExit(context, state)
            elseif scene == "save-as" then
                context.editorDrawerModule.openName(context, state, "Sonic1")
            end
            if state.drawerFields then
                -- Stitched pages hide leading rows, up to DRAWER_SHIFT pixels,
                -- so rows that would need scrolling move into view. The
                -- native dialog scrolls to its focused row, so hiding rows
                -- (which are not focusable) is used instead of offsetting them.
                local _, config = state.handlers.editor.settings(state.session)
                local function shown(field)
                    local condition = field.visibleWhen
                    if type(condition) == "function" then return condition(config) end
                    if type(condition) ~= "table" then return true end
                    local matches = config[condition.key] == condition.value
                    if condition.invert then return not matches end
                    return matches
                end
                local function height(field)
                    if not shown(field) then return 0 end
                    return field.type == "section" and math.floor(state.drawerControlHeight * 0.625)
                        or state.drawerRowHeight
                end
                local shift, total = 0, 0
                for _, field in ipairs(state.drawerFields) do
                    total = total + height(field)
                end
                for _, field in ipairs(state.drawerFields) do
                    local rowHeight = height(field)
                    if rowHeight > 0 then
                        if shift + rowHeight > DRAWER_SHIFT then break end
                        shift = shift + rowHeight
                        field.visibleWhen = function() return false end
                    end
                end
                context.captureDrawer = string.format("drawer shift %d total %d row %d\\n",
                    shift, total, state.drawerRowHeight)
            end
            context.captureSceneOpened = true
            context.captureSettled = 0
            return
        end
        if "SCENE" == "navigation-tape" and not context.captureToggled then
            for _, row in ipairs(state.drawerControls) do
                if row.field.key == "showTape" then
                    state.drawerPending = { action = "write", field = row.field, value = true, control = row }
                    break
                end
            end
            lvgl.close(state.nativeDrawer)
            context.captureToggled = true
            return
        end
        if "SCENE" == "navigation-tape" and not context.captureResized then
            assert(state.handlers.editor.resize(state.session, 0, -1))
            assert(state.handlers.preview(state.session.draft))
            context.captureResized = true
            return
        end
        context.captureSettled = context.captureSettled + 1
        if context.captureSettled < 15 or context.captureReady then return end
        local file = assert(io.open("/capture-ready.txt", "w"))
        io.write(file, "production editor scene ready\\n")
        if context.captureDrawer then
            io.write(file, context.captureDrawer)
        end
        io.close(file)
        context.captureReady = true
    end,
""".replace("SCENE", scene).replace("DRAWER_SHIFT", str(shift)))
    main.write_text(source)


def decode(frame):
    rgb = bytearray()
    for (pixel,) in struct.iter_unpack("<H", frame):
        rgb.extend(((pixel >> 11) * 255 // 31, ((pixel >> 5) & 63) * 255 // 63,
                    (pixel & 31) * 255 // 31))
    return [bytes(rgb[y * 480 * 3:(y + 1) * 480 * 3]) for y in range(272)]


def write_png(path, rows):
    def chunk(kind, data):
        return (struct.pack(">I", len(data)) + kind + data
                + struct.pack(">I", zlib.crc32(kind + data)))
    width = len(rows[0]) // 3
    path.write_bytes(b"\x89PNG\r\n\x1a\n"
                     + chunk(b"IHDR", struct.pack(">IIBBBBB", width, len(rows), 8, 2, 0, 0, 0))
                     + chunk(b"IDAT", zlib.compress(b"".join(b"\0" + row for row in rows)))
                     + chunk(b"IEND", b""))


def dialog_geometry(rows):
    """Locate the native dialog's title bar and scrolling body in one frame."""
    pixel = lambda x, y: rows[y][x * 3:x * 3 + 3]
    # Title text is short, so its rows still contain mostly title color.
    title = max((pixel(x, 40) for x in range(480)), key=lambda color: rows[40].count(color))
    count = lambda y: sum(pixel(x, y) == title for x in range(480))
    top = 40
    while top > 0 and count(top - 1) > 240:
        top -= 1
    body = 40
    while count(body) > 240:
        body += 1
    edge = [x for x in range(480) if pixel(x, top + 1) == title]
    left, right = edge[0], edge[-1] + 1
    background = pixel(left + 2, body + 1)
    bottom = body
    while bottom < 272 and pixel(left + 2, bottom) == background:
        bottom += 1
    return left, right, top, body, bottom, background


def stitch(frames, guard):
    """Join the title bar and successive body pages into one tall drawer image.

    Each frame is (rows, shift): its body shows drawer content starting
    ``shift`` pixels down. Content within ``guard`` pixels of a later page's
    top (blank margin and its focused first row) comes from the page before.
    """
    left, right, top, body, bottom, background = dialog_geometry(frames[0][0])
    height = bottom - body
    crop = lambda row: row[left * 3:right * 3]
    # Paint over the native scrollbar, which reflects only the hidden-row page.
    clear = lambda row: row[:-12 * 3] + background * 12
    output = [crop(row) for row in frames[0][0][top:body]]
    blank = background * (right - left)
    end = frames[-1][1] + height
    content = []
    for offset in range(end):
        for index, (rows, shift) in enumerate(frames):
            if offset < shift + height and (index == 0 or offset >= shift + guard):
                content.append(clear(crop(rows[body + offset - shift])))
                break
        else:
            raise RuntimeError(f"Stitched pages do not cover drawer offset {offset}")
    used = [index for index, row in enumerate(content) if row != blank]
    if not used:
        raise RuntimeError("Drawer capture has no content")
    return output + content[:min(len(content), used[-1] + 1 + used[0])]


def capture(executable, library, directory, scene, shift=0):
    if directory.is_symlink():
        raise RuntimeError(f"Capture directory must not be a symlink: {directory}")
    if directory.exists():
        shutil.rmtree(directory)
    directory.mkdir()
    sd = directory / "sdcard"
    prepare(sd, scene, shift)
    regions = directory / "regions.txt"
    regions.write_text("0 0 480 272\n")
    frame = directory / "frame.rgb565"
    mode = "fullscreen"
    if scene == "navigation-location":
        actions = directory / "actions.txt"
        actions.write_text(
            "500 200 140 1\n600 200 140 0\n"
            "850 100 80 1\n860 100 80 0\n1000 410 245 1\n1010 410 245 0\n"
            "1150 100 80 1\n1160 100 80 0\n1300 410 245 1\n1310 410 245 0\n"
            "1450 100 80 1\n1460 100 80 0\n")
        mode = "actions=" + str(actions)
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
    drawer = None
    for line in (sd / "capture-ready.txt").read_text().splitlines():
        words = line.split()
        if words[:1] == ["drawer"]:
            drawer = dict(zip(words[1::2], map(int, words[2::2])))
    return decode(pixels), drawer


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
        rows, drawer = capture(executable, library, directory, scene)
        if scene in STITCHED_SCENES:
            if drawer is None:
                raise RuntimeError(f"{scene} did not report drawer geometry")
            _, _, _, body, bottom, _ = dialog_geometry(rows)
            height = bottom - body
            guard = drawer["row"] + 24
            frames = [(rows, 0)]
            # 24 px allows for the dialog's own top padding around the rows.
            while frames[-1][1] + height < drawer["total"] + 24:
                page, report = capture(executable, library,
                                       directory.with_name(f"{scene}-page{len(frames)}"),
                                       scene, frames[-1][1] + height - guard)
                if report["shift"] <= frames[-1][1]:
                    raise RuntimeError(f"{scene} drawer rows do not fit one page")
                frames.append((page, report["shift"]))
            rows = stitch(frames, guard)
        write_png(directory / f"{scene}.png", rows)
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
                   "Native TX16S framebuffer; isolated sample layouts and editor command automation."
                   + (" Configuration drawers are cropped to the dialog and stitched from pages whose "
                      "leading rows are hidden in the isolated copy; the native scrollbar is painted over."
                      if set(STITCHED_SCENES) & set((args.scene,) if args.scene else SCENES) else "")),
        "scenes": (args.scene,) if args.scene else SCENES + tuple(SETUP_SCENES),
    }, indent=2) + "\n")


if __name__ == "__main__":
    main()

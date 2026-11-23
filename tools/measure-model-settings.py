# SPDX-License-Identifier: GPL-2.0-only
"""Measure Model row callbacks in the native Companion TX16S simulator."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]

# getUsage() reports the PREVIOUS LVGL refresh, not the current instruction count
# (EdgeTX lua_widget.cpp / LuaWidget::checkEvents and api_general.cpp / luaGetUsage).
# Run one production row per refresh without other host work, then sample it in
# the next refresh. Counts include wrapper overhead and firmware property polling.
# EdgeTX 2.12 lua_widget.cpp / MAX_INSTRUCTIONS and widgets.cpp / luaHook:
# one percent is 200 instructions; use the next bucket as an exclusive bound.
REFRESH = """
    refresh = function(context, event, touch)
        if not context.measureRows then
            refresh(context, event, touch)
            assert(#context.errors == 0, table.concat(context.errors, "\\n"))
            if not isFullScreen() or context.stage or context.reloadState then return end
            if not context.modelSettingsUi then
                if context.aeroMenuHandlers then context.aeroMenuHandlers.modelSettings() end
                return
            end
            context.measureRows = {}
            return
        end
        local state = context.modelSettingsUi
        if context.measurePrevious then
            local sample = context.measurePrevious
            sample.percent = getUsage()
            context.measureRows[#context.measureRows + 1] = sample
            context.measurePrevious = nil
        end
        if state.build then
            local sample = { row = state.build, slots = context.modelSettingsUiModule.cost(context) }
            context.modelSettingsUiModule.advance(context)
            sample.key = context.measureField
            context.measurePrevious = sample
        elseif not context.measureDone then
            local file = assert(io.open("/rows.txt", "w"))
            for _, sample in ipairs(context.measureRows) do
                io.write(file, string.format("%d %s %d %d\\n", sample.row, sample.key, sample.slots, sample.percent))
            end
            io.close(file)
            file = assert(io.open("/capture-ready.txt", "w"))
            io.write(file, "Model row measurements complete")
            io.close(file)
            context.measureDone = true
        end
    end,
"""

REFRESH_CALLBACKS = """
    refresh = function(context, event, touch)
        context.measureCallbacks = context.measureCallbacks or {}
        if context.measurePrevious then
            context.measurePrevious.percent = getUsage()
            context.measureCallbacks[#context.measureCallbacks + 1] = context.measurePrevious
            context.measurePrevious = nil
        end
        context.measureFields, context.measureSlots = {}, 0
        refresh(context, event, touch)
        assert(#context.errors == 0, table.concat(context.errors, "\\n"))
        if #context.measureFields > 0 then
            context.measurePrevious = { fields = context.measureFields, slots = context.measureSlots }
        end
        if not isFullScreen() or context.stage or context.reloadState or context.measureDone then return end
        if not context.measureRequested and context.aeroMenuHandlers then
            context.measureRequested = true
            context.aeroMenuHandlers.modelSettings()
        end
        local state = context.modelSettingsUi
        if not state or state.build or context.measurePrevious then return end
        local file = assert(io.open("/rows.txt", "w"))
        for _, sample in ipairs(context.measureCallbacks) do
            io.write(file, string.format("%d %d %s\\n",
                sample.percent, sample.slots, table.concat(sample.fields, ",")))
        end
        io.close(file)
        file = assert(io.open("/capture-ready.txt", "w"))
        io.write(file, "Complete Model construction callbacks measured")
        io.close(file)
        context.measureDone = true
    end,
"""

ROWS = (
    "armed", "motorSource", "motorReversed", "requireReceiver",
    "minMotorPercent", "minFlightDuration", "disarmDuration", "smartDetection",
    "countSource", "flightSwitch", "sessionReset", "finish",
)


def parse_samples(text):
    samples = []
    for line in text.splitlines():
        index, key, grant, usage = line.split()
        row, slots, percent = int(index), int(grant), int(usage)
        if row != len(samples) + 1 or row > len(ROWS) or not 1 <= slots <= 8 or not 0 <= percent <= 100:
            raise RuntimeError(f"Unexpected row measurement: {line}")
        if key != ROWS[row - 1]:
            raise RuntimeError(f"Model row order changed: {line}")
        if percent >= slots * 10:
            raise RuntimeError(f"Row {ROWS[row - 1]} does not fit its {slots}-slot grant: {percent}%")
        samples.append({
            "row": ROWS[row - 1],
            "slots": slots,
            "callback_percent": percent,
            "callback_instructions_below": (percent + 1) * 200,
        })
    if len(samples) != len(ROWS):
        raise RuntimeError(f"Expected {len(ROWS)} row measurements, got {len(samples)}")
    return samples


def parse_callbacks(text):
    samples, rows = [], []
    for line in text.splitlines():
        usage, grant, fields = line.split()
        percent, slots = int(usage), int(grant)
        keys = fields.split(",")
        if not 0 <= percent < 75:
            raise RuntimeError(f"Construction callback exceeds the 15,000-instruction envelope: {line}")
        if slots != sum(2 if key == "flightSwitch" else 1 for key in keys) or slots > 8:
            raise RuntimeError(f"Unexpected construction grants: {line}")
        rows.extend(keys)
        samples.append({
            "rows": keys,
            "model_slots": slots,
            "callback_percent": percent,
            "callback_instructions_below": (percent + 1) * 200,
        })
    if tuple(rows) != ROWS:
        raise RuntimeError(f"Unexpected construction row order: {rows}")
    return samples


def measure_native(companion, output, instrument):
    """Run isolated SD instrumentation shared by the two drawer profilers."""
    library = companion / "Contents/Resources/libedgetx-tx16s-simulator.dylib"
    if not library.is_file():
        raise RuntimeError(f"Simulator library not found: {library}")
    architectures = subprocess.check_output(["lipo", "-archs", str(library)], text=True).split()
    if len(architectures) != 1:
        raise RuntimeError("A single-architecture simulator library is required.")
    spec = importlib.util.spec_from_file_location("capture_editor", ROOT / "tools/capture-editor.py")
    capture = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(capture)
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="settings-measurement-", dir=output.parent) as temporary:
        directory = Path(temporary)
        sd = directory / "sd"
        capture.prepare(sd, "model-settings-motor")
        instrument(sd)
        executable = directory / "capture-native"
        subprocess.run(["clang++", "-std=c++11", "-arch", architectures[0],
                        str(ROOT / "tools/capture-native.cpp"),
                        f"-Wl,-rpath,{companion / 'Contents/Frameworks'}",
                        "-o", str(executable)], check=True)
        regions = directory / "regions.txt"
        regions.write_text("0 0 480 272\n")
        log_path = output.with_suffix(".log")
        with log_path.open("w") as log:
            subprocess.run([str(executable), str(library), str(sd),
                            str(directory / "frame.rgb565"), str(regions), "fullscreen"],
                           stdout=log, stderr=subprocess.STDOUT, check=True, timeout=45)
        text = (sd / "rows.txt").read_text()
        output.with_suffix(".txt").write_text(text)
        return text, hashlib.sha256(library.read_bytes()).hexdigest()


def instrument_model(sd, mode):
    main_path = sd / "WIDGETS/AeroGrid/main.lua"
    source = (ROOT / "src/WIDGETS/AeroGrid/main.lua").read_text()
    needle = "    refresh = refresh,"
    if source.count(needle) != 1:
        raise RuntimeError("Widget entry changed; update row measurement instrumentation")
    main_path.write_text(source.replace(needle, REFRESH if mode == "rows" else REFRESH_CALLBACKS))
    ui_path = sd / "WIDGETS/AeroGrid/lib/model_settings_ui.lua"
    source = ui_path.read_text()
    if mode == "rows":
        needle = "function ui.advance(context)"
        if source.count(needle) != 1:
            raise RuntimeError("Model UI entry changed; update row measurement instrumentation")
        source = source.replace(needle, needle + """
    if not context.measureRows then return false end
""")
    needle = "        local shared = context.settingsUiModule"
    if source.count(needle) != 1:
        raise RuntimeError("Model row lookup changed; update row measurement instrumentation")
    instrumentation = '\n        context.measureField = fields[state.build] and fields[state.build].key or "finish"'
    if mode == "callbacks":
        instrumentation = """
        context.measureFields[#context.measureFields + 1] = fields[state.build] and fields[state.build].key or "finish"
        context.measureSlots = context.measureSlots + ui.cost(context)"""
    ui_path.write_text(source.replace(needle, needle + instrumentation))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--companion", type=Path, default=Path("/Applications/EdgeTX Companion 2.12.app"))
    parser.add_argument("--output", type=Path, default=ROOT / "build/model-settings-measurement.json")
    parser.add_argument("--mode", choices=("rows", "callbacks"), default="rows")
    args = parser.parse_args()
    text, simulator_hash = measure_native(args.companion, args.output, lambda sd: instrument_model(sd, args.mode))
    parse = parse_samples if args.mode == "rows" else parse_callbacks
    samples = parse(text)
    report = {
        "evidence": "Native Companion simulator, NOT physical-radio timing or safety evidence",
        "method": ("Previous-refresh getUsage; one row plus firmware property polling and wrapper overhead"
                   if args.mode == "rows" else
                   "Previous-refresh getUsage; complete production refresh plus firmware property polling and wrapper overhead"),
        "simulator_sha256": simulator_hash,
        "source_sha256": hashlib.sha256((ROOT / "src/WIDGETS/AeroGrid/lib/model_settings_ui.lua").read_bytes()).hexdigest(),
        "shared_ui_sha256": hashlib.sha256((ROOT / "src/WIDGETS/AeroGrid/lib/settings_ui.lua").read_bytes()).hexdigest(),
        args.mode: samples,
    }
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()

# SPDX-License-Identifier: GPL-2.0-only
"""Measure every catalog panel's shared settings UI in native Companion."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

REFRESH = """
    refresh = function(context, event, touch)
        if context.measurePrevious then
            context.measurePrevious.percent = getUsage()
            context.measureSamples[#context.measureSamples + 1] = context.measurePrevious
            context.measurePrevious = nil
        end
        context.measureSteps = {}
        local state = context.editorUi
        local isolated = MEASURE_ROWS and context.measureCurrent and state
            and (state.drawerBuild or state.drawerPending)
        if isolated then
            context.editorUiModule.advance(context)
        else
            refresh(context, event, touch)
        end
        assert(#context.errors == 0, table.concat(context.errors, "\\n"))
        if #context.measureSteps > 0 then
            context.measurePrevious = {
                name = context.measureCurrent.name,
                steps = context.measureSteps,
            }
        end
        if not isFullScreen() or context.stage or context.reloadState or context.measureDone then return end
        if not context.editorUi then
            assert(context.editorController.openEditor(context), "cannot open editor")
            return
        end
        state = context.editorUi
        if state.buildStage or state.previewPending or state.previewRefresh
            or state.drawerBuild or state.drawerPending or state.nativeInput then return end
        if not context.measureScenarios then
            context.measureSamples, context.measureScenarios = {}, {}
            for _, item in ipairs(state.handlers.editor.CATALOG) do
                context.measureScenarios[#context.measureScenarios + 1] = { name = item.type, panel = item.type }
            end
            for _, item in ipairs({
                { name = "metric-entry", panel = "metric", key = "metrics", path = { 1 } },
                { name = "chart-entry", panel = "chart", key = "metrics", path = { 1 } },
                { name = "state-entry", panel = "state", key = "entries", path = { 1 } },
                { name = "state-condition", panel = "state", key = "entries", path = { 1, "states", 1 } },
                { name = "rx-battery-bar", panel = "rx-battery", patch = { visual = "bar" } },
                { name = "rx-battery-none", panel = "rx-battery", patch = { visual = "none" } },
                { name = "navigation-tape", panel = "navigation", patch = { showTape = true } },
                { name = "host-diagnostics-log", panel = "host-diagnostics", patch = { section = "log" } },
            }) do
                context.measureScenarios[#context.measureScenarios + 1] = item
            end
            local selected = { MEASURE_DRAWERS }
            for index = #context.measureScenarios, 1, -1 do
                if not selected[context.measureScenarios[index].name] then
                    table.remove(context.measureScenarios, index)
                end
            end
            local advance = context.editorUiModule.advance
            context.editorUiModule.advance = function(c)
                local s = c.editorUi
                if not c.measureCurrent or not s or not (s.drawerBuild or s.drawerPending) then
                    return advance(c)
                end
                local index = s.drawerBuild
                local field = index and s.drawerFields[index]
                local tag = index and (field and "row:" .. index or "finish") or s.drawerPending.action
                local slots = MEASURE_ROWS
                    and (index and c.settingsUiModule.cost(s.drawerView, 8, 8) or 8)
                    or c.uiTasks.editor.cost
                local result = advance(c)
                if field then tag = tag .. ":" .. s.drawerControls[index].kind end
                c.measureSteps[#c.measureSteps + 1] = tag .. "=" .. slots
                return result
            end
        end
        local current = context.measureCurrent
        if current and current.phase == "build" then
            current.phase = "edit"
            for _, entry in ipairs(state.drawerControls) do
                local field = entry.field
                if field.type == "boolean" then
                    state.drawerPending = {
                        action = "write", field = field, control = entry,
                        value = not state.drawerView.read(field),
                    }
                    return
                end
            end
        end
        if current and current.phase == "edit" then
            current.phase = "close"
            state.drawerPending = { action = "back" }
            return
        end
        if context.measurePrevious then return end
        context.measureIndex = (context.measureIndex or 0) + 1
        current = context.measureScenarios[context.measureIndex]
        context.measureCurrent = current
        if not current then
            local file = assert(io.open("/rows.txt", "w"))
            for _, sample in ipairs(context.measureSamples) do
                io.write(file, sample.name .. " " .. sample.percent .. " " .. table.concat(sample.steps, ",") .. "\\n")
            end
            io.close(file)
            file = assert(io.open("/capture-ready.txt", "w"))
            io.write(file, "All catalog and dynamic settings drawers measured")
            io.close(file)
            context.measureDone = true
            return
        end
        state.session.draft.panels = {}
        state.session.selected = nil
        assert(state.handlers.editor.add(state.session, current.panel))
        local config = state.session.draft.panels[state.session.selected].config
        if current.panel == "metric" or current.panel == "chart" then
            config.metrics = {
                { source = "gvar1", label = "First" },
                { source = "gvar1", label = "Second" },
                { source = "gvar1", label = "Third" },
            }
        elseif current.panel == "state" then
            config.entries = {}
            for index = 1, 3 do
                config.entries[index] = {
                    label = "Entry " .. index,
                    states = {
                        { switch = "SA^", text = "UP" },
                        { switch = "SA-", text = "MID" },
                        { switch = "SAv", text = "DOWN" },
                    },
                }
            end
        end
        for key, value in pairs(current.patch or {}) do config[key] = value end
        current.phase = "build"
        state.drawerPending = current.key
            and { action = "item", key = current.key, itemPath = current.path }
            or { action = "parent" }
    end,
"""

EXPECTED = {
    "output", "chart", "flight-counter", "flight-mode", "flight-timer",
    "host-diagnostics", "link-status", "metric", "model-identity", "navigation",
    "rx-battery", "state", "trim-panel", "tx-battery",
    "metric-entry", "chart-entry", "state-entry", "state-condition",
    "rx-battery-bar", "rx-battery-none", "navigation-tape", "host-diagnostics-log",
}


def parse_samples(text, mode):
    samples, finished, kinds = [], set(), set()
    indices = {}
    for line in text.splitlines():
        name, usage, steps = line.split()
        percent = int(usage)
        if name not in EXPECTED or not 0 <= percent < 75:
            raise RuntimeError(f"Unexpected or over-budget drawer callback: {line}")
        parsed = []
        for step in steps.split(","):
            tag, reservation = step.split("=")
            slots = int(reservation)
            if not 1 <= slots <= 8:
                raise RuntimeError(f"Invalid reservation: {line}")
            if tag.startswith("row:"):
                _, index, kind = tag.split(":")
                if int(index) != indices.get(name, 0) + 1:
                    raise RuntimeError(f"Skipped or repeated row: {line}")
                indices[name] = int(index)
                kinds.add(kind)
                if mode == "rows" and percent >= 10:
                    raise RuntimeError(f"Row exceeds one native slot: {line}")
            elif tag == "finish":
                if name in finished or not indices.get(name) or slots != 8:
                    raise RuntimeError(f"Unexpected finalization: {line}")
                finished.add(name)
            elif tag not in ("parent", "item", "write", "back") or slots != 8:
                raise RuntimeError(f"Unexpected lifecycle step: {line}")
            parsed.append({"step": tag, "slots": slots})
        if mode == "rows" and len(parsed) != 1 or mode == "callbacks" and sum(s["slots"] for s in parsed) > 8:
            raise RuntimeError(f"Unexpected callback packing: {line}")
        samples.append({
            "drawer": name, "steps": parsed, "callback_percent": percent,
            "callback_instructions_below": (percent + 1) * 200,
        })
    if finished != EXPECTED:
        raise RuntimeError(f"Missing completed drawers: {sorted(EXPECTED - finished)}")
    if not {"source", "switch", "toggle", "choice", "timer", "numberEdit", "textEdit", "button", "label"} <= kinds:
        raise RuntimeError(f"Missing shared control coverage: {sorted(kinds)}")
    return samples


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--companion", type=Path, default=Path("/Applications/EdgeTX Companion 2.12.app"))
    parser.add_argument("--output", type=Path, default=ROOT / "build/panel-settings-measurement.json")
    parser.add_argument("--mode", choices=("rows", "callbacks"), default="rows")
    args = parser.parse_args()
    spec = importlib.util.spec_from_file_location("measure_model", ROOT / "tools/measure-model-settings.py")
    runner = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(runner)

    texts = []
    names = sorted(EXPECTED)
    # Keep each run inside the capture driver's 30-second simulator limit.
    batch_size = 12 if args.mode == "callbacks" else len(names)
    for offset in range(0, len(names), batch_size):
        selected = ", ".join(f'["{name}"] = true' for name in names[offset:offset + batch_size])

        def instrument(sd):
            main_path = sd / "WIDGETS/AeroGrid/main.lua"
            source = (ROOT / "src/WIDGETS/AeroGrid/main.lua").read_text()
            needle = "    refresh = refresh,"
            if source.count(needle) != 1:
                raise RuntimeError("Widget entry changed; update drawer measurement instrumentation")
            wrapper = REFRESH.replace("MEASURE_ROWS", str(args.mode == "rows").lower())
            main_path.write_text(source.replace(needle, wrapper.replace("MEASURE_DRAWERS", selected)))

        output = args.output.with_name(f"{args.output.stem}-{offset // batch_size + 1}.json")
        text, simulator_hash = runner.measure_native(args.companion, output, instrument)
        texts.append(text)
    samples = parse_samples("\n".join(text.strip() for text in texts), args.mode)
    report = {
        "evidence": "Native Companion simulator, NOT physical-radio timing or safety evidence",
        "method": "Previous-refresh getUsage; includes firmware polling and measurement overhead",
        "mode": args.mode, "simulator_sha256": simulator_hash,
        "source_sha256": {
            path: hashlib.sha256((ROOT / "src/WIDGETS/AeroGrid" / path).read_bytes()).hexdigest()
            for path in ("main.lua", "lib/settings_ui.lua", "lib/editor_drawer.lua", "lib/editor_ui.lua")
        },
        "samples": samples,
    }
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    peak = max(sample["callback_instructions_below"] for sample in samples)
    print(f"{len(EXPECTED)} drawers, {len(samples)} callbacks; all below {peak} instructions; {args.output}")


if __name__ == "__main__":
    main()

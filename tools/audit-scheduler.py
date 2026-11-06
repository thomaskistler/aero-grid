#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Measure scheduler task costs with an exact instruction count in the native simulator.

Each scenario runs the real widget in an isolated copy of the EdgeTX 2.12 macOS
simulator with every Lua instruction counted (see audit-native.cpp). Results go
to build/scheduler-audit/<scenario>/results.json.
"""
import argparse
import importlib.util
import json
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys

TOOLS = Path(__file__).resolve().parent
sys.path.insert(0, str(TOOLS))
from scheduler_audit import (CASE_DIR, PROBE_DIR, ROOT, SUPPORT_DIR, WIDGET, lua_literal, patch_chart,  # noqa: E402
                             patch_loader, patch_main, patch_mode, patch_owners, aggregate, framework_report, hook_check_status,
                             reduce_results, supported_spans)
from capture_recipes import PANELS, RECIPE_DIR, fixture_inputs, load_recipe  # noqa: E402

OUTPUT = ROOT / "build/scheduler-audit"
COMPANION = Path("/Applications/EdgeTX Companion 2.12.app")
TRACE_DIR = ROOT / "tests/fixtures/scheduler-traces"
MODEL_SETTINGS = "version: 1\nmodelFilename: model1.yml\nrevision: 1\narmed: SAv\n"
REFLOW_STAGES = {
    "metric": ("begin", "geometry", "apply"),
    "link-status": ("begin", "geometry", "apply"),
    "tx-battery": ("begin", "reading", "visual", "publish"),
    "flight-timer": ("update",),
    "navigation": ("begin", "render", "reading", "tape-frame", "tape"),
    "chart": ("begin", "font", "layout", "position", "finish"),
    "output": ("begin", "hide", "subscribe", "captions", "place", "render", "apply"),
    "theme-showcase": ("begin", "place"),
    "flight-counter": ("update",),
    "flight-mode": ("update",),
    "model-identity": ("update",),
    "state": ("begin", "fit", "check", "fallback", "apply"),
    "trim-panel": ("update",),
    "host-diagnostics": ("update",),
    "service-probe": ("update",),
}


def capture_module():
    spec = importlib.util.spec_from_file_location("capture", TOOLS / "capture-panels.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def standard_phases(refreshes=400, backgrounds=100):
    return [
        {"name": "refresh", "kind": "refresh", "callbacks": refreshes, "step": 5, "perCall": 20, "trace": True},
        {"name": "background", "kind": "background", "callbacks": backgrounds, "step": 5, "perCall": 20},
    ]


SMART_SOURCES = (
    {"name": "Alt", "id": 9, "instance": 0, "unit": 9, "prec": 1, "value": 120},
    {"name": "GSpd", "id": 2, "instance": 2, "unit": 7, "prec": 1, "value": 40},
    {"name": "GPS", "id": 2, "instance": 0, "unit": 40, "prec": 0, "value": None},
    {"name": "Sats", "id": 2, "instance": 5, "unit": 0, "prec": 0, "value": 12},
)


def synthetic_inputs(names, smart=False, reset=False):
    """Lua service inputs for plain named sources and a cyclic arm switch.

    `names` is a count (sources S01..Snn) or a list of names. With `smart`, a
    CRSF module and the four sensors Smart flight detection looks for are added.
    """
    names = [f"S{index:02d}" for index in range(1, names + 1)] if isinstance(names, int) else list(names)
    rows = []
    if smart:
        rows += [f'    {{ name = "{s["name"]}", id = {s["id"]}, instance = {s["instance"]}, unit = {s["unit"]}, '
                 f'prec = {s["prec"]}, type = 0, value = '
                 + ('{ lat = 47.0, lon = 8.0, delay = 0 }' if s["value"] is None else str(s["value"])) + " }"
                 for s in SMART_SOURCES]
    rows += [f'    {{ name = "{name}", id = {0x0A00 + index}, instance = 0, unit = 0, prec = 0, type = 0, '
             f"value = 500 }}" for index, name in enumerate(names)]
    body = ",\n".join(rows)
    module_type = "5" if smart else "0"
    reset_index = 'assert(getSwitchIndex("SB" .. CHAR_DOWN))' if reset else "nil"
    return f"""local sources = {{
{body}
}}
local byKey = {{}}
for index, source in ipairs(sources) do
    source.field = 30000 + index
    byKey[source.field] = source
    byKey[source.name] = byKey[source.name] or source
end
local armIndex = assert(getSwitchIndex("SA" .. CHAR_DOWN))
local resetIndex = {reset_index}
local function find(key)
    return byKey[key]
end
return {{
    getFieldInfo = function(name)
        local source = find(name)
        if source then return {{ name = source.name, id = source.field, unit = source.unit, prec = source.prec }} end
        local telemetry = type(name) == "string" and tonumber(string.match(name, "^telem(%d+)$"))
        if telemetry and sources[telemetry] then return {{ id = sources[telemetry].field }} end
        return getFieldInfo(name)
    end,
    getValue = function(id)
        local source = find(id)
        if source then return source.value end
        return getValue(id)
    end,
    getSourceValue = function(id)
        local source = find(id)
        if source then return source.value, true, true end
        return getSourceValue(id)
    end,
    getSwitchValue = function(index)
        if index == armIndex then return getTime() % 5000 < 4800 end
        if index == resetIndex then return getTime() % 1000 < 500 end
        return getSwitchValue(index)
    end,
    getRSSI = function() return 85 end,
    model = setmetatable({{
        getSensor = function(index) return sources[index + 1] end,
        getModule = function(index) return {{ Type = index == 0 and {module_type} or 0 }} end,
    }}, {{ __index = model }}),
}}
"""


def metric_cell(index, sources):
    names = "".join(f"        - source: S{sources[i]:02d}\n          precision: 0\n" for i in range(len(sources)))
    return (f"  - id: m{index}\n    type: metric\n    col: {(index - 1) % 4}\n    row: {(index - 1) // 4}\n"
            f"    colSpan: 1\n    rowSpan: 1\n    config:\n      metrics:\n{names}")


def chart_cell(name, row, rows, sources):
    metrics = "".join(f"        - source: S{source:02d}\n          precision: 0\n" for source in sources)
    return (f"  - id: {name}\n    type: chart\n    col: 0\n    row: {row}\n    colSpan: 4\n    rowSpan: {rows}\n"
            f"    config:\n      metrics:\n{metrics}")


def custom_layout(cells):
    return "version: 5\ngrid:\n  columns: 4\n  rows: 4\npanels:\n" + "".join(cells)


def scenarios():
    result = {}
    replay = ("metric-16", "stress", "flight-smart", "session-reset", "chart-full")
    for panel in PANELS:
        small, large = supported_spans(panel)
        for tag, (cols, rows) in (("min", small), ("max", large)):
            result[f"{panel}-{tag}"] = {
                "recipe": panel, "placements": {"subject": (0, 0, cols, rows)}, "expected": 1,
                "phases": standard_phases(), "baseInputs": True,
            }
    result["metric-16"] = {
        "recipe": "metric", "placements": {f"m{i}": ((i - 1) % 4, (i - 1) // 4, 1, 1) for i in range(1, 17)},
        "expected": 16, "baseInputs": True,
        "phases": standard_phases() + [
            {"name": "reflow", "kind": "refresh", "action": "reflow", "callbacks": 40, "step": 5, "perCall": 1},
            {"name": "reload", "kind": "refresh", "action": "reload", "callbacks": 10, "step": 5, "perCall": 1},
        ],
    }
    link = [{"name": "RQly"}, {"name": "1RSS"}, {"name": "RFMD"}, {"name": "RSNR"}, {"name": "TPWR"}]
    result["link-extrema"] = {
        "recipe": "link-status", "placements": {"subject": (0, 0, 2, 2)}, "expected": 1, "settings": True,
        "config": {"extrema": "flight"}, "sources": [item["name"] for item in link],
        "phases": standard_phases(),
    }
    cells = [chart_cell("chart-a", 0, 1, (1, 2, 3)), chart_cell("chart-b", 1, 1, (4, 5, 6))]
    for index in range(8):
        cell = metric_cell(index + 1, (7 + index * 3, 8 + index * 3, 9 + index * 3))
        cells.append(cell.replace(f"    col: {index % 4}\n    row: {index // 4}\n",
                                  f"    col: {index % 4}\n    row: {2 + index // 4}\n"))
    result["stress"] = {
        "recipe": "metric", "layout": custom_layout(cells), "expected": 10, "sources": 30, "settings": True,
        "phases": standard_phases(),
    }
    # Every panel that reads the model service: identity, flight mode, a timer, and
    # TX voltage with battery range (five facets, one more than an update reads).
    model_cells = [("model-identity", 0, 0, 2, 2), ("flight-mode", 2, 0, 2, 1), ("flight-timer", 2, 1, 2, 1),
                   ("tx-battery", 0, 2, 2, 2)]
    result["model-panels"] = {
        "recipe": "flight-timer", "expected": len(model_cells),
        "layout": custom_layout([f"  - id: {panel}\n    type: {panel}\n    col: {col}\n    row: {row}\n"
                                 f"    colSpan: {cols}\n    rowSpan: {rows}\n" for panel, col, row, cols, rows
                                 in model_cells]),
        "phases": standard_phases(),
    }
    result["default-gallery"] = {
        "recipe": "metric", "layout": (WIDGET / "layouts/Default.yaml").read_text(),
        "expected": 9, "settings": True, "toggleSwitches": True, "phases": standard_phases(),
    }
    for name, base in (("editor-preview-metric", result["metric-16"]),
                       ("editor-preview-chart", result["chart-max"])):
        result[name] = dict(base, fullscreen=True, phases=[
            {"name": "settle", "kind": "refresh", "callbacks": 40, "step": 5, "perCall": 4},
            {"name": "editor-build", "kind": "refresh", "action": "open-editor",
             "callbacks": 80, "step": 5, "perCall": 4},
            {"name": "editor-preview", "kind": "refresh", "action": "check-editor",
             "callbacks": 120, "step": 5, "perCall": 4},
            {"name": "editor-render", "kind": "refresh", "action": "select-editor",
             "callbacks": 20, "step": 5, "perCall": 4},
            {"name": "editor-render-check", "kind": "refresh", "action": "check-render",
             "callbacks": 1, "step": 5, "perCall": 1},
            {"name": "editor-close", "kind": "refresh", "action": "close-editor",
             "callbacks": 40, "step": 5, "perCall": 4},
        ])
    result["editor-preview-metric-tasks"] = dict(result["editor-preview-metric"], owners=["panel:metric"])
    result["editor-preview-chart-tasks"] = dict(result["editor-preview-chart"], owners=["panel:chart"])
    theme_source = (WIDGET / "themes/modern-dark.yml").read_text()
    result["theme-resolution-corrections"] = dict(result["metric-max"], themeSource=re.sub(
        r"(?m)^(  \w+: )0x[0-9A-Fa-f]+", r"\g<1>0x777777",
        theme_source.replace("correctForContrast: false", "correctForContrast: true").replace(
            "colors:\n", "colors:\n  chartCyan: 0x777777\n  chartGreen: 0x777777\n"
            "  chartAmber: 0x777777\n  chartOrange: 0x777777\n")),
        phases=standard_phases())
    layout_header = "\n".join(f'metadata_{index}: "retained # text" # ' + "comment " * 24
                              for index in range(128))
    layout_panels = custom_layout([
        "  - id: readings\n    type: metric\n    col: 0\n    row: 0\n    colSpan: 4\n    rowSpan: 4\n"
        "    config:\n      metrics:\n" + "".join(
            f"        - source: {source}\n          label: Reading\n          unit: x\n"
            "          precision: 1\n          rangeMin: 0\n          rangeMax: 100\n"
            "          warning: 80\n          critical: 95\n          direction: rising\n"
            for source in ("Alt", "Curr", "VFAS")),
    ])
    result["layout-loading-chunks"] = dict(result["metric-max"], expected=1,
        layout=layout_panels.replace("panels:\n", layout_header +
            "\nretained:\n  - item: first\n    values:\n      - one\n      - two\npanels:\n"),
        phases=standard_phases())
    invalid_layout = custom_layout([]).replace("version: 5", "version: 999")
    result["layout-loading-error"] = dict(result["metric-max"], expected=0,
        layout=invalid_layout, fallbackLayout=invalid_layout,
        expectedError="unsupported layout version", phases=standard_phases())
    for panel in (*PANELS, "theme-showcase"):
        base = result["metric-max"] if panel == "theme-showcase" else result[f"{panel}-max"]
        result[f"panel-reflow-{panel}"] = dict(base, phases=standard_phases() + [
            {"name": "reflow", "kind": "refresh", "action": "reflow", "callbacks": 60, "step": 5, "perCall": 1},
        ])
        if panel in ("output", "tx-battery"):
            for phase in result[f"panel-reflow-{panel}"]["phases"]:
                phase["trace"] = phase["name"] == "reflow"
        if panel == "theme-showcase":
            result[f"panel-reflow-{panel}"]["layout"] = custom_layout([
                "  - id: subject\n    type: theme-showcase\n    col: 0\n    row: 0\n"
                "    colSpan: 4\n    rowSpan: 4\n",
            ])
    result["modal-log"] = dict(result["host-diagnostics-max"], fullscreen=True, logEntries=256,
        config={"section": "log", "maxEntries": 256}, phases=[
            {"name": "settle", "kind": "refresh", "callbacks": 40, "step": 5, "perCall": 4},
            {"name": "log-build", "kind": "refresh", "action": "open-log",
             "callbacks": 120, "step": 5, "perCall": 4},
            {"name": "log-idle", "kind": "refresh", "action": "check-log",
             "callbacks": 40, "step": 5, "perCall": 4},
            {"name": "log-scroll", "kind": "refresh", "action": "scroll-log",
             "callbacks": 40, "step": 5, "perCall": 4},
            {"name": "log-close", "kind": "refresh", "action": "close-log",
             "callbacks": 10, "step": 5, "perCall": 1},
        ])
    result["modal-settings"] = dict(result["chart-max"], fullscreen=True, phases=[
        {"name": "settle", "kind": "refresh", "callbacks": 40, "step": 5, "perCall": 4},
        {"name": "settings-build", "kind": "refresh", "action": "open-settings",
         "callbacks": 200, "step": 5, "perCall": 4},
        {"name": "settings-idle", "kind": "refresh", "action": "check-settings",
         "callbacks": 40, "step": 5, "perCall": 4},
        {"name": "settings-close", "kind": "refresh", "action": "close-settings",
         "callbacks": 10, "step": 5, "perCall": 1},
    ])
    settings_cells = [
        ("chart", "chart", 0, 0, 2, "      metrics:\n        - source: S01\n"),
        ("link", "link-status", 2, 0, 1, "      reading: quality\n      qualitySource: S02\n"),
        ("counter", "flight-counter", 2, 1, 1, ""),
        ("home", "navigation", 0, 2, 1, "      homeMode: first-arm\n"),
        ("radio-home", "navigation", 2, 2, 1, "      homeMode: edgetx\n"),
        ("battery", "rx-battery", 0, 3, 1, "      source: S03\n      cells: 0\n"),
        ("timer", "flight-timer", 2, 3, 1, ""),
    ]
    result["modal-settings-reset"] = dict(result["modal-settings"], recipe="metric", sources=3, expected=7, settings=True,
        settingsDocument="version: 1\nmodelFilename: model1.yml\nrevision: 1\narmed: L64\nsessionReset: L03\n"
                         "flight:\n  motorSource: ch32\n  flightSwitch: L64\n",
        layout=custom_layout([
            f"  - id: {name}\n    type: {kind}\n    col: {col}\n    row: {row}\n"
            f"    colSpan: 2\n    rowSpan: {height}\n"
            + ("    config:\n" + config if config else "    config: {}\n")
            for name, kind, col, row, height, config in settings_cells
        ]))
    phases = list(result["modal-settings-reset"]["phases"])
    phases[-1:-1] = [
        {"name": "settings-save", "kind": "refresh", "action": "edit-settings",
         "callbacks": 80, "step": 5, "perCall": 4},
        {"name": "settings-saved", "kind": "refresh", "action": "check-settings-save",
         "callbacks": 1, "step": 5, "perCall": 1},
    ]
    result["modal-settings-save"] = dict(result["modal-settings-reset"], phases=phases,
        settingsDocument=result["modal-settings-reset"]["settingsDocument"].replace("flightSwitch: L64", 'flightSwitch: ""'))
    result["modal-settings-save-output"] = dict(result["modal-settings-save"],
        settingsDocument=result["modal-settings-save"]["settingsDocument"].replace('flightSwitch: ""', "flightSwitch: L63"))
    for ending in ("open", "return", "native", "fullscreen", "explicit", "error", "replaced"):
        phases = list(result["modal-settings-save"]["phases"][:3])
        phases += [{"name": "publication-start", "kind": "refresh", "action": "edit-settings",
                   "armed": ending != "error", "reject": ending == "error", "members": 128,
                   "callbacks": 128, **({} if ending == "error" else {"untilSettings": "publish_members"}),
                   "step": 5, "perCall": 1}]
        if ending == "replaced":
           phases += [{"name": "publication-replaced", "kind": "refresh", "action": "replace-publication",
                       "callbacks": 8, "step": 5}]
        elif ending not in ("open", "error"):
           phases += [{"name": "confirmed-close", "kind": "refresh", "action": "dismiss-settings",
                       "dismiss": ending, "callbacks": 256, "untilSettings": "closed", "step": 5}]
        else:
           phases += [{"name": "publication-finish", "kind": "refresh", "callbacks": 160, "step": 5}]
        phases += [{"name": "publication-checked", "kind": "refresh",
                   "action": "check-settings-error" if ending in ("error", "replaced") else "check-settings-save",
                   "callbacks": 1, "step": 5}]
        result[f"modal-settings-publication-{ending}"] = dict(result["modal-settings-save"], phases=phases,
           expectedError=("Model settings: injected save failure" if ending == "error" else
                          "Model settings: Model settings publication was replaced" if ending == "replaced" else None))
    phases = list(result["modal-settings-publication-open"]["phases"])
    phases[3] = dict(phases[3], kind="background")
    phases[4] = dict(phases[4], kind="background")
    result["modal-settings-publication-background"] = dict(result["modal-settings-publication-open"], phases=phases)
    phases = list(result["modal-settings-save"]["phases"][:3]) + [
        {"name": "settings-return", "kind": "refresh", "event": "EVT_VIRTUAL_EXIT",
         "callbacks": 1, "step": 5},
    ]
    result["modal-settings-close-return"] = dict(result["modal-settings-save"], phases=phases)
    for suffix, base in (("metric", result["metric-16"]), ("multi", result["modal-settings-reset"]),
                         ("model", result["model-panels"]), ("output", result["output-max"])):
        result[f"lifecycle-app-{suffix}"] = dict(base, fullscreen=True, phases=[
            {"name": "settle", "kind": "refresh", "callbacks": 40, "step": 5, "perCall": 4},
            {"name": "app-rebuild", "kind": "refresh", "action": "lifecycle-app",
             "callbacks": 400, "step": 5, "perCall": 1, "trace": True},
            {"name": "app-check", "kind": "refresh", "action": "check-lifecycle",
             "callbacks": 1, "step": 5, "perCall": 1},
            {"name": "retire", "kind": "refresh", "action": "lifecycle-retire",
             "callbacks": 400, "step": 5, "perCall": 1, "trace": True},
            {"name": "retire-check", "kind": "refresh", "action": "check-lifecycle",
             "callbacks": 1, "step": 5, "perCall": 1},
        ])
    construction_parity = dict(result["metric-max"], fullscreen=True, constructionParity=True, phases=[
        {"name": "settle", "kind": "refresh", "callbacks": 40, "step": 5, "perCall": 1},
        {"name": "begin", "kind": "refresh", "action": "construction-parity",
         "callbacks": 1, "step": 5, "perCall": 1},
        {"name": "compare", "kind": "refresh", "advance": "construction-parity-step",
         "untilConstruction": True, "callbacks": 10000, "step": 5, "perCall": 1},
        {"name": "checked", "kind": "refresh", "action": "construction-parity-check",
         "callbacks": 1, "step": 5, "perCall": 1},
    ])
    construction_cost = dict(construction_parity, phases=[
        dict(phase, **({"action": "construction-cost"} if phase.get("action") == "construction-parity" else {}))
        for phase in construction_parity["phases"]
    ])
    construction_cost["phases"][2]["callbacks"] = 40000
    result["rx-reflow-matrix"] = dict(
        construction_parity, constructionKind="rx-battery", phases=[
            dict(phase, **({"action": "rx-reflow-matrix"} if phase.get("action") == "construction-parity" else {}))
            for phase in construction_parity["phases"]
        ])
    result["rx-reflow-cost"] = dict(result["rx-reflow-matrix"], phases=[
        dict(phase, **({"action": "rx-reflow-cost"} if phase.get("action") == "rx-reflow-matrix" else {}))
        for phase in result["rx-reflow-matrix"]["phases"]
    ])
    for kind in REFLOW_STAGES:
        for operation in ("matrix", "cost"):
            result[f"reflow-{operation}-{kind}"] = dict(
                construction_parity, reflowKind=kind, phases=[
                    dict(phase, **({"action": f"panel-reflow-{operation}"}
                                  if phase.get("action") == "construction-parity" else {}))
                    for phase in construction_parity["phases"]
                ])
    for kind in ("metric", "link-status", "rx-battery", "tx-battery", "flight-timer"):
        for operation in ("parity", "cost"):
            result[f"construction-{operation}-{kind}"] = dict(
                construction_parity if operation == "parity" else construction_cost, constructionKind=kind)
    for kind in ("metric", "link-status", "rx-battery", "tx-battery", "flight-timer"):
        for size in ("min", "max"):
            for visual in (("bar", "radial") if kind == "metric" else
                           ("bar", "battery", "none") if kind == "rx-battery" else
                           ("bar", "battery") if kind.endswith("battery") else
                           ("bar", "none") if kind == "link-status" else ("none",)):
                base = result[f"{kind}-{size}"]
                result[f"lifecycle-construct-{kind}-{size}-{visual}"] = dict(
                    base, fullscreen=True, config=dict(base.get("config", {}), visual=visual),
                    phases=result["lifecycle-app-model"]["phases"])
                if kind == "rx-battery":
                    result[f"lifecycle-construct-{kind}-{size}-{visual}-tasks"] = dict(
                        result[f"lifecycle-construct-{kind}-{size}-{visual}"],
                        owners=["panel:rx-battery"])
    result["lifecycle-cancel"] = dict(result["modal-settings-reset"], fullscreen=True, phases=[
        {"name": "settle", "kind": "refresh", "callbacks": 40, "step": 5, "perCall": 4},
        {"name": "partial", "kind": "refresh", "action": "lifecycle-app",
         "callbacks": 400, "untilPartialConstruction": True, "step": 5, "perCall": 1},
        {"name": "cancel", "kind": "refresh", "action": "lifecycle-cancel",
         "callbacks": 400, "step": 5, "perCall": 1, "trace": True},
        {"name": "cancel-check", "kind": "refresh", "action": "check-lifecycle",
         "callbacks": 1, "step": 5, "perCall": 1},
    ])
    result["lifecycle-settings-drain"] = dict(result["modal-settings-save"], lifecycleDrain=True, phases=[
        {"name": "settle", "kind": "refresh", "callbacks": 40, "step": 5, "perCall": 4},
        {"name": "settings-build", "kind": "refresh", "action": "open-settings",
         "callbacks": 200, "step": 5, "perCall": 1},
        {"name": "settings-confirm", "kind": "refresh", "action": "edit-settings",
         "callbacks": 1, "step": 5, "perCall": 1},
        {"name": "settings-drain", "kind": "refresh", "action": "lifecycle-settings-drain",
         "callbacks": 400, "step": 5, "perCall": 1, "trace": True},
        {"name": "settings-drained", "kind": "refresh", "action": "check-lifecycle-settings",
         "callbacks": 1, "step": 5, "perCall": 1},
    ])
    for kind in ("refresh", "background"):
        result[f"lifecycle-restart-root-{kind}"] = dict(result["output-max"], fullscreen=True, phases=[
            {"name": "settle", "kind": "refresh", "callbacks": 40, "step": 5, "perCall": 1},
            {"name": "retire-root", "kind": kind, "action": "lifecycle-retire", "recreateRoot": True,
             "callbacks": 400, "step": 5, "perCall": 1, "trace": True},
            {"name": "root-checked", "kind": "refresh", "action": "check-lifecycle",
             "callbacks": 1, "step": 5, "perCall": 1},
        ])
        result[f"lifecycle-error-finish-{kind}"] = dict(result["output-max"], fullscreen=True,
            expectedError="injected lifecycle error " + "x" * 256, phases=[
                {"name": "settle", "kind": "refresh", "callbacks": 40, "step": 5, "perCall": 1},
                {"name": "new-error-label", "kind": kind, "action": "lifecycle-error-finish",
                 "callbacks": 1, "step": 5, "perCall": 1, "trace": True},
                {"name": "existing-error-label", "kind": kind, "action": "lifecycle-error-finish",
                 "callbacks": 1, "step": 5, "perCall": 1, "trace": True},
                {"name": "errors-checked", "kind": "refresh", "action": "check-lifecycle-errors",
                 "callbacks": 1, "step": 5, "perCall": 1},
            ])
    opening_source = result["modal-settings-reset"]["settingsDocument"].replace(
        "revision: 1", "revision: 12").replace("  motorSource: ch32", "  motorReversed: true\n  motorSource: ch32")
    edited_source = ("# retained comment\n" * 64 + opening_source
        + '  history:\n    - name: "' + "quoted # text " * 16 + '" # ' + "inline comment " * 64
        + "\n      points: [1, 2]\n  announcements:\n    - name: old\n      enabled: true\n")
    for mode in ("primary", "edited", "recovered", "missing", "legacy-none", "legacy-one", "legacy-conflict",
                 "return", "fullscreen", "identity", "invalid", "background",
                 "publish-return", "publish-fullscreen", "publish-explicit", "retirement"):
        source = edited_source if mode in ("edited", "background", "return", "fullscreen", "identity") else opening_source
        if mode.startswith("legacy-") or mode == "retirement":
            source = source.replace("armed: L64\n", "")
        elif mode.startswith("publish-"):
            source = source.replace("armed: L64", "armed: L62")
        elif mode == "missing":
            source = False
        elif mode in ("recovered", "invalid"):
            source = "version: 0\n"
        preparation = {"name": "opening-source", "kind": "refresh", "action": "prepare-settings-source",
            "source": source, "members": 128, "legacy": "one" if mode == "retirement" else mode.removeprefix("legacy-"),
            "backup": opening_source if mode == "recovered" else "version: 99\n" if mode == "invalid" else False,
            "callbacks": 1, "step": 5}
        interrupted = mode in ("return", "fullscreen", "identity", "invalid") or mode.startswith("publish-")
        phases = [result["modal-settings-reset"]["phases"][0], preparation,
            {"name": "opening-read", "kind": "background" if mode == "background" else "refresh",
             "action": "open-settings", "callbacks": 800, "step": 5, "perCall": 1,
             "untilSettings": ("closed" if mode == "invalid" else "load_publish_members" if mode.startswith("publish-")
                 else "load_legacy" if mode == "retirement" else "load_parse" if interrupted else "idle"),
             "untilSettingsCursor": mode == "retirement"}]
        if mode == "retirement":
            phases += [{"name": "opening-retirement", "kind": "refresh", "action": "retire-settings-member",
                "callbacks": 800, "untilSettings": "idle", "step": 5}]
        elif interrupted and mode != "invalid":
            phases += [{"name": "opening-cancel", "kind": "refresh",
                "action": "fail-settings-identity" if mode == "identity" else "dismiss-settings",
                "dismiss": mode.removeprefix("publish-"),
                "callbacks": 200, "untilSettings": "closed", "step": 5}]
        phases += [{"name": "opening-checked", "kind": "refresh", "action": "check-settings-open",
            "closed": interrupted, "revision": 0 if mode == "missing" else 12, "reversed": mode != "missing",
            "published": mode.startswith("publish-"),
            "missing": mode == "missing", "recovered": mode == "recovered",
            "legacy": ("No model Armed" if mode == "legacy-none" else "Old widget Armed was not imported"
                       if mode in ("legacy-one", "retirement") else "Conflicting old widget" if mode == "legacy-conflict" else False),
            "callbacks": 1, "step": 5}]
        result[f"modal-settings-open-{mode}"] = dict(result["modal-settings-reset"], phases=phases,
            expectedError=("Model settings: injected opening identity failure" if mode == "identity" else
                "Model settings: Cannot load model settings: Unsupported model settings schema; expected version 1; "
                "Unsupported model settings schema; expected version 1" if mode == "invalid" else None))
    result["lifecycle-admission-background"] = dict(result["lifecycle-app-output"], phases=[
        dict(phase, kind="background", action="lifecycle-app-background") if phase["name"] == "app-rebuild"
        else dict(phase, kind="background") if phase["name"] == "retire" else dict(phase)
        for phase in result["lifecycle-app-output"]["phases"]
    ])
    result["lifecycle-preparation"] = dict(result["metric-max"], fullscreen=True, preparation=True, phases=[
        {"name": "begin", "kind": "refresh", "action": "preparation",
         "callbacks": 1, "step": 5, "perCall": 1},
        {"name": "prepare", "kind": "refresh", "advance": "preparation-step", "untilPreparation": True,
         "callbacks": 6000, "step": 5, "perCall": 1},
        {"name": "checked", "kind": "refresh", "action": "preparation-check",
         "callbacks": 1, "step": 5, "perCall": 1},
    ])
    result["lifecycle-retire-admission-16"] = dict(result["metric-16"], fullscreen=True,
        owners=["panel:metric"], phases=[
            {"name": "settle", "kind": "refresh", "callbacks": 80, "step": 5, "perCall": 1},
            {"name": "retire", "kind": "refresh", "action": "lifecycle-retire",
             "callbacks": 400, "step": 5, "perCall": 1, "trace": True},
            {"name": "retire-check", "kind": "refresh", "action": "check-lifecycle",
             "callbacks": 1, "step": 5, "perCall": 1},
        ])
    result["modal-log-recording"] = dict(result["modal-log"], recipe="chart", sources=1, expected=2,
        settings=True, layout=custom_layout([
            chart_cell("chart", 0, 2, [1]),
            "  - id: log\n    type: host-diagnostics\n    col: 0\n    row: 2\n"
            "    colSpan: 4\n    rowSpan: 2\n    config:\n      section: log\n      maxEntries: 256\n",
        ]))
    result["modal-location"] = dict(result["navigation-max"], fullscreen=True, phases=[
        {"name": "settle", "kind": "refresh", "callbacks": 80, "step": 5, "perCall": 4},
        {"name": "location-open", "kind": "refresh", "action": "open-location",
         "callbacks": 40, "step": 5, "perCall": 4},
        {"name": "location-close", "kind": "refresh", "action": "close-location",
         "callbacks": 10, "step": 5, "perCall": 1},
        {"name": "location-reopen", "kind": "refresh", "action": "open-location",
         "callbacks": 40, "step": 5, "perCall": 4},
    ])
    result["modal-menu"] = dict(result["chart-max"], fullscreen=True, phases=[
        {"name": "settle", "kind": "refresh", "callbacks": 40, "step": 5, "perCall": 4},
        {"name": "menu-open", "kind": "refresh", "action": "open-menu",
         "callbacks": 40, "step": 5, "perCall": 4},
        {"name": "menu-idle", "kind": "refresh", "action": "check-menu",
         "callbacks": 40, "step": 5, "perCall": 4},
        {"name": "menu-select", "kind": "refresh", "action": "select-menu",
         "callbacks": 20, "step": 5, "perCall": 4},
        {"name": "menu-close", "kind": "refresh", "action": "close-menu",
         "callbacks": 10, "step": 5, "perCall": 1},
    ])
    result["lifecycle-menu-close"] = dict(result["modal-menu"], fullscreen=True, lifecycleMenuClose=True, phases=[
        {"name": "settle", "kind": "refresh", "callbacks": 40, "step": 5, "perCall": 4},
        {"name": "menu-open", "kind": "refresh", "action": "open-menu",
         "callbacks": 40, "step": 5, "perCall": 1},
        {"name": "menu-checked", "kind": "refresh", "action": "check-menu",
         "callbacks": 1, "step": 5, "perCall": 1},
        {"name": "menu-retire", "kind": "background", "action": "lifecycle-menu-retire",
         "callbacks": 1, "step": 5, "perCall": 1},
        {"name": "menu-close", "kind": "background", "callbacks": 400, "step": 5, "perCall": 1,
         "trace": True},
        {"name": "menu-retired", "kind": "background", "action": "check-lifecycle-menu",
         "callbacks": 1, "step": 5, "perCall": 1},
    ])
    for panel in ("navigation", "metric", "chart"):
        result[f"editor-rebuild-{panel}"] = dict(result[f"{panel}-max"], fullscreen=True, phases=[
            {"name": "settle", "kind": "refresh", "callbacks": 40, "step": 5, "perCall": 4},
            {"name": "editor-build", "kind": "refresh", "action": "open-editor",
             "callbacks": 80, "step": 5, "perCall": 4},
            {"name": "preview-rebuild", "kind": "refresh", "action": "edit-preview",
             "callbacks": 80, "step": 5, "perCall": 4},
            {"name": "preview-check", "kind": "refresh", "action": "check-preview",
             "callbacks": 1, "step": 5, "perCall": 1},
            {"name": "editor-close", "kind": "refresh", "action": "discard-editor",
             "callbacks": 40, "step": 5, "perCall": 4},
        ])
    for panel in PANELS:
        result[f"editor-drawer-{panel}"] = dict(result[f"{panel}-max"], fullscreen=True, phases=[
            {"name": "settle", "kind": "refresh", "callbacks": 40, "step": 5, "perCall": 4},
            {"name": "editor-build", "kind": "refresh", "action": "open-editor",
             "callbacks": 80, "step": 5, "perCall": 4},
            {"name": "drawer-build", "kind": "refresh", "action": "open-drawer",
             "callbacks": 240, "step": 5, "perCall": 4},
            {"name": "drawer-check", "kind": "refresh", "action": "check-drawer",
             "callbacks": 1, "step": 5, "perCall": 1},
            {"name": "editor-close", "kind": "refresh", "action": "close-editor",
             "callbacks": 10, "step": 5, "perCall": 1},
        ])
        phases = list(result[f"editor-drawer-{panel}"]["phases"])
        phases[2] = {key: value for key, value in phases[2].items() if key != "action"}
        phases[2]["event"] = "EVT_VIRTUAL_ENTER"
        result[f"editor-input-{panel}"] = dict(result[f"editor-drawer-{panel}"], phases=phases)
    phases = list(result["editor-input-metric"]["phases"][:2])
    for event in ("EVT_ROT_RIGHT", "EVT_ROT_LEFT", "EVT_VIRTUAL_NEXT", "EVT_VIRTUAL_PREV", "EVT_TOUCH_BREAK"):
        phases.append({"name": event, "kind": "refresh", "event": event,
                       "callbacks": 1, "step": 5})
    phases += [{"name": "selection-finish", "kind": "refresh", "callbacks": 16, "step": 5},
               {"name": "selection-check", "kind": "refresh", "action": "check-render",
                "callbacks": 1, "step": 5}]
    phases += list(result["editor-input-metric"]["phases"][2:])
    phases[-2:-2] = [{"name": "native-input", "kind": "refresh", "event": "EVT_VIRTUAL_ENTER",
                     "callbacks": 1, "step": 5}]
    result["editor-input-keys"] = dict(result["editor-input-metric"], phases=phases)
    phases = list(result["editor-input-metric"]["phases"][:2]) + [
        {"name": "last-panel-first", "kind": "refresh", "action": "prepare-editor-tap",
         "event": "EVT_TOUCH_FIRST", "callbacks": 1, "step": 5},
        {"name": "last-panel-tap", "kind": "refresh", "action": "prepare-editor-tap",
         "event": "EVT_TOUCH_TAP", "callbacks": 240, "step": 5, "perCall": 4},
        {"name": "tap-drawer-check", "kind": "refresh", "action": "check-drawer",
         "callbacks": 1, "step": 5},
        {"name": "duplicate-tap", "kind": "refresh", "action": "prepare-editor-tap",
         "event": "EVT_TOUCH_TAP", "callbacks": 1, "step": 5},
    ] + list(result["editor-input-metric"]["phases"][-1:])
    result["editor-input-tap"] = dict(result["metric-16"], fullscreen=True, phases=phases)
    phases = list(result["editor-input-metric"]["phases"][:2]) + [
        {"name": "panel-picker", "kind": "refresh", "action": "select-editor-add",
         "event": "EVT_VIRTUAL_ENTER", "callbacks": 16, "step": 5},
        {"name": "panel-picker-check", "kind": "refresh", "action": "check-render",
         "callbacks": 1, "step": 5},
    ]
    result["editor-input-add"] = dict(result["editor-input-metric"], phases=phases)
    phases = list(result["editor-input-metric"]["phases"][:2]) + [
        {"name": "queue-drawer", "kind": "refresh", "event": "EVT_VIRTUAL_ENTER",
         "callbacks": 1, "step": 5},
        {"name": "cancel-drawer", "kind": "refresh", "event": "EVT_VIRTUAL_EXIT",
         "callbacks": 1, "step": 5},
        {"name": "cancel-check", "kind": "refresh", "action": "check-drawer-cancelled",
         "callbacks": 1, "step": 5},
    ]
    result["editor-input-cancel"] = dict(result["editor-input-metric"], phases=phases)
    for panel in ("metric", "chart", "state"):
        base = result[f"editor-drawer-{panel}"]
        phases = list(base["phases"])
        phases[-1:-1] = [
            {"name": "entry-build", "kind": "refresh", "action": "open-entry-drawer",
             "callbacks": 160, "step": 5, "perCall": 4},
            {"name": "entry-check", "kind": "refresh", "action": "check-drawer",
             "callbacks": 1, "step": 5, "perCall": 1},
        ]
        result[f"editor-entry-{panel}"] = dict(base, phases=phases)
    for panel in PANELS:
        base = result[f"editor-drawer-{panel}"]
        phases = list(base["phases"][:-1]) + [
            {"name": "drawer-write", "kind": "refresh", "action": "write-drawer",
             "key": {"navigation": "showTape", "rx-battery": "visual", "chart": "timeRange"}.get(panel, False),
             "callbacks": 100, "step": 5, "perCall": 4},
            {"name": "drawer-written", "kind": "refresh", "action": "check-drawer-write",
             "callbacks": 1, "step": 5},
            {"name": "editor-discard", "kind": "refresh", "action": "discard-editor",
             "callbacks": 20, "step": 5},
        ]
        result[f"editor-write-{panel}"] = dict(base, phases=phases)
    for panel in ("metric", "chart", "state"):
        base = result[f"editor-entry-{panel}"]
        phases = list(base["phases"][:-1]) + [
            {"name": "entry-write", "kind": "refresh", "action": "write-drawer",
             "callbacks": 100, "step": 5, "perCall": 4},
            {"name": "entry-written", "kind": "refresh", "action": "check-drawer-write",
             "callbacks": 1, "step": 5},
            {"name": "editor-discard", "kind": "refresh", "action": "discard-editor",
             "callbacks": 20, "step": 5},
        ]
        result[f"editor-write-entry-{panel}"] = dict(base, phases=phases)
    phases = list(result["editor-write-link-status"]["phases"])
    phases[-3] = dict(phases[-3], reject=True)
    result["editor-write-error"] = dict(result["editor-write-link-status"], phases=phases)
    phases = list(result["editor-write-link-status"]["phases"])
    phases[-3] = dict(phases[-3], nativeError=True)
    result["editor-write-picker-error"] = dict(result["editor-write-link-status"], phases=phases)
    phases = list(result["editor-entry-state"]["phases"])
    phases[-1:-1] = [
        {"name": "state-build", "kind": "refresh", "action": "open-entry-drawer",
         "callbacks": 160, "step": 5, "perCall": 4},
        {"name": "state-check", "kind": "refresh", "action": "check-drawer",
         "callbacks": 1, "step": 5, "perCall": 1},
    ]
    result["editor-state-detail"] = dict(result["editor-entry-state"], phases=phases)
    result["editor-rebuild-navigation-tape"] = dict(result["editor-rebuild-navigation"],
                                                     config={"showTape": False})
    for tag in ("min", "max", "16"):
        result[f"metric-tasks-{tag}"] = dict(result[f"metric-{tag}"], owners=["panel:metric"],
                                            phases=standard_phases())
        base = result[f"navigation-{tag}"] if tag != "16" else dict(result["metric-16"], recipe="navigation")
        result[f"navigation-tasks-{tag}"] = dict(base, owners=["panel:navigation"], phases=standard_phases(),
                                                config={"showTape": True, "showCoordinates": True,
                                                        "satelliteSource": "Sats"})
    result["navigation-tasks-bearing"] = dict(result["navigation-tasks-max"],
                                               config={"showTape": False, "showCoordinates": True,
                                                       "satelliteSource": "Sats"})
    result["navigation-tasks-4"] = dict(result["navigation-tasks-max"], expected=4, placements={
        f"n{i}": ((i - 1) % 2 * 2, (i - 1) // 2 * 2, 2, 2) for i in range(1, 5)})
    for tag in ("min", "max", "16"):
        base = result[f"link-status-{tag}"] if tag != "16" else dict(result["metric-16"], recipe="link-status")
        result[f"link-status-tasks-{tag}"] = dict(
            base, owners=["panel:link-status"], phases=standard_phases(), toggleLink=True,
            config={"protocol": "elrs4", "reading": "quality", "rssiSource": "1RSS", "qualitySource": "RQly",
                    "modeSource": "RFMD", "snrSource": "RSNR", "powerSource": "TPWR", "visual": "bar"})
    result["link-status-tasks-generic"] = dict(result["link-status-tasks-max"],
        config={"protocol": "generic", "reading": "rssi", "rssiSource": "1RSS", "qualitySource": "RQly",
                "modeSource": "RFMD", "snrSource": "RSNR", "powerSource": "TPWR",
                "extrema": "source", "extremaSource": "1RSS-", "visual": "bar"})
    for service in ("telemetry", "model", "control", "navigation"):
        for tag in ("min", "max", "4"):
            base = result[f"service-probe-{tag}"] if tag != "4" else {
                "recipe": "service-probe", "expected": 4, "baseInputs": True,
                "placements": {f"p{i}": ((i - 1) % 2 * 2, (i - 1) // 2 * 2, 2, 2) for i in range(1, 5)}}
            result[f"service-probe-tasks-{service}-{tag}"] = dict(
                base, owners=["panel:service-probe"], phases=standard_phases(),
                config={"service": service, "source": "trim-ail" if service == "control" else "GPS" if service == "navigation" else "RSSI",
                        "index": 0})
    for section in ("identity", "theme", "panels", "sources", "log"):
        for tag in ("min", "max", "4"):
            base = result[f"host-diagnostics-{tag}"] if tag != "4" else {
                "recipe": "host-diagnostics", "expected": 4, "baseInputs": True,
                "placements": {f"d{i}": ((i - 1) % 2 * 2, (i - 1) // 2 * 2, 2, 2) for i in range(1, 5)}}
            result[f"host-diagnostics-tasks-{section}-{tag}"] = dict(
                base, owners=["panel:host-diagnostics"], phases=standard_phases(),
                config={"section": section, "maxEntries": 256}, logEntries=256 if section == "log" else 0,
                diagnosticsSources=8 if section == "sources" else 0)
            if section == "sources":
                result[f"host-diagnostics-tasks-{section}-{tag}"]["sources"] = 8
    for panel in ("flight-counter", "flight-mode", "flight-timer", "state", "trim-panel", "tx-battery", "model-identity"):
        for tag in ("min", "max", "16"):
            base = result[f"{panel}-{tag}"] if tag != "16" else dict(result["metric-16"], recipe=panel)
            result[f"{panel}-tasks-{tag}"] = dict(base, owners=[f"panel:{panel}"], phases=standard_phases(),
                                                  toggleSwitches=panel == "state")
    result["light-control"] = {
        "recipe": "trim-panel", "expected": 2, "toggleSwitches": True,
        "layout": custom_layout([
            "  - id: mode\n    type: state\n    col: 0\n    row: 0\n    colSpan: 2\n    rowSpan: 1\n"
            "    config:\n      entries:\n        - label: MODE\n          states:\n"
            "            - switch: SF^\n              text: DISARMED\n"
            "            - switch: SFv\n              text: ARMED\n",
            "  - id: trims\n    type: trim-panel\n    col: 2\n    row: 0\n    colSpan: 2\n    rowSpan: 2\n"
            "    config:\n      scale: standard\n      readout: percent\n",
        ]),
        "phases": standard_phases(),
    }
    result["control-panel-tasks"] = dict(result["light-control"], owners=["panel:state", "panel:trim-panel"])
    for tag in ("min", "max", "16"):
        base = result[f"rx-battery-{tag}"] if tag != "16" else dict(result["metric-16"], recipe="rx-battery")
        result[f"rx-battery-tasks-{tag}"] = dict(base, owners=["panel:rx-battery"], phases=standard_phases(),
                                                  config={"visual": "bar", "showPack": True,
                                                          "showCount": True, "showDelta": True})
    result["flight-smart"] = {
        "recipe": "metric", "expected": 2, "sources": 3, "settings": True, "smart": True,
        "layout": custom_layout([chart_cell("chart-a", 0, 2, (1, 2, 3)),
                                 "  - id: counter\n    type: flight-counter\n    col: 0\n    row: 2\n"
                                 "    colSpan: 2\n    rowSpan: 1\n    config:\n      armSwitch: SAv\n"]),
        "phases": standard_phases(refreshes=800),
    }
    result["flight-smart-tasks"] = dict(result["flight-smart"], flightTasks=True,
                                      owners=["service:flight", "service:smart"])
    result["flight-smart-tasks-background"] = dict(result["flight-smart-tasks"],
        phases=[{"name": "background", "kind": "background", "callbacks": 800, "step": 5, "perCall": 20},
                {"name": "refresh", "kind": "refresh", "callbacks": 100, "step": 5, "perCall": 20}])
    result["flight-smart-tasks-no-counter"] = dict(result["flight-smart-tasks"], expected=1,
        layout=custom_layout([metric_cell(1, (1, 2, 3))]))
    result["session-reset"] = {
        "recipe": "metric", "expected": 2, "sources": 6, "settings": True, "reset": True,
        "layout": custom_layout([chart_cell("chart-a", 0, 2, (1, 2, 3)),
                                 metric_cell(1, (4, 5, 6)).replace("row: 0", "row: 2")]),
        "phases": standard_phases(refreshes=800),
    }
    result["session-reset-tasks"] = dict(result["session-reset"], owners=["panel:chart", "panel:metric"])
    result["theme-showcase-tasks"] = dict(
        result["host-diagnostics-max"], owners=["panel:theme-showcase"], phases=standard_phases(),
        layout=custom_layout(["  - id: showcase\n    type: theme-showcase\n    col: 0\n    row: 0\n"
                              "    colSpan: 4\n    rowSpan: 4\n"]))
    result["chart-full"] = {
        "recipe": "metric", "layout": custom_layout([chart_cell("chart-a", 0, 4, (1, 2, 3))]), "expected": 1,
        "sources": 3, "settings": True,
        "phases": [
            {"name": "fill", "kind": "refresh", "callbacks": 21000, "step": 50, "perCall": 25},
            {"name": "refresh", "kind": "refresh", "callbacks": 800, "step": 5, "perCall": 20, "trace": True},
            {"name": "background", "kind": "background", "callbacks": 100, "step": 5, "perCall": 20},
        ],
    }
    for name in replay:
        result[name]["trace"] = True
    for tag, base in (("gallery", "default-gallery"), ("stress", "stress"),
                      ("model", "model-panels"), ("flight-smart", "flight-smart")):
        result[f"migration-tasks-{tag}"] = dict(
            result[base], flightTasks=True,
            owners=["service:flight", "service:smart"] + [f"panel:{panel}" for panel in PANELS])
    loops = [0, 100, 400, 800, 1600, 3000, 6000, 9000]
    for name in ("hook-check", "hook-check-firmware"):
        result[name] = {"recipe": "metric", "placements": {"subject": (0, 0, 1, 1)}, "expected": 1,
                        "baseInputs": True, "phases": [], "loops": loops}
    return result


def build_native(library):
    OUTPUT.mkdir(parents=True, exist_ok=True)
    executable = OUTPUT / "audit-native"
    architecture = subprocess.check_output(["lipo", "-archs", str(library)], text=True).split()
    if architecture != ["x86_64"]:
        raise RuntimeError("The instruction counter patches x86_64 code; select the x86_64 simulator library.")
    subprocess.run(["clang++", "-std=c++11", "-arch", "x86_64", str(TOOLS / "audit-native.cpp"),
                    f"-Wl,-rpath,{COMPANION / 'Contents/Frameworks'}", "-o", str(executable)], check=True)
    return executable


def prepare(capture, name, spec, sd, mode="legacy"):
    if spec.get("flightTasks") and mode != "mixed":
        raise ValueError("Flight adapter scenarios require --mode mixed")
    recipe_path = RECIPE_DIR / f"{spec['recipe']}.yaml"
    recipe = load_recipe(recipe_path)
    if "placements" in spec:
        recipe["panels"] = {key: {"col": col, "row": row, "colSpan": cs, "rowSpan": rs}
                            for key, (col, row, cs, rs) in spec["placements"].items()}
    recipe["config"].update(spec.get("config", {}))
    capture.prepare(sd, recipe, recipe_path)
    widget = sd / "WIDGETS/AeroGrid"
    if "themeSource" in spec:
        (widget / "themes/modern-dark.yml").write_text(spec["themeSource"])
    audit = widget / "audit"
    audit.mkdir()
    # Capture's own readiness hooks are replaced; start again from the shipped sources.
    shutil.copyfile(WIDGET / "main.lua", widget / "main.lua")
    shutil.copyfile(WIDGET / "lib/dashboard_loader.lua", widget / "lib/dashboard_loader.lua")
    (widget / "main.lua").write_text(patch_mode(patch_main((WIDGET / "main.lua").read_text()), mode))
    if spec.get("lifecycleDrain"):
        source = (widget / "main.lua").read_text()
        anchor = ('    if context.modelSettingsUi then\n'
                  '        local bound = context.modelSettingsUiModule.workBound(context, widgetEvent)\n')
        if source.count(anchor) != 1:
            raise RuntimeError("Lifecycle settings drain requires one foreground modal gate")
        source = source.replace(anchor,
            '    if _G.AUDIT_LIFECYCLE_DRAIN and context.reloadState == "clear" then\n'
            '        advanceLifecycle(context, "retirePage")\n'
            '        return\n'
            '    end\n' + anchor)
        (widget / "main.lua").write_text(source)
    (widget / "lib/dashboard_loader.lua").write_text(patch_loader((WIDGET / "lib/dashboard_loader.lua").read_text()))
    (widget / "lib/scheduler_host.lua").write_text(
        patch_owners((WIDGET / "lib/scheduler_host.lua").read_text(), spec.get("owners", [])))
    (widget / "panels/chart.lua").write_text(patch_chart((WIDGET / "panels/chart.lua").read_text()))
    if "layout" in spec:
        (widget / "layouts/capture-panels.yaml").write_text(spec["layout"])
    if "fallbackLayout" in spec:
        (widget / "layouts/Default.yaml").write_text(spec["fallbackLayout"])
    if spec.get("settings"):
        settings = sd / "AEROGRID/models"
        settings.mkdir(parents=True, exist_ok=True)
        (settings / ("model1.yml".encode().hex() + ".yaml")).write_text(
            spec.get("settingsDocument", MODEL_SETTINGS + ("sessionReset: SBv\n" if spec.get("reset") else ""))
            + ("flight:\n  smartDetection: true\n  minFlightDuration: 1\n  disarmDuration: 3\n"
               if spec.get("smart") else ""))
    inputs = (synthetic_inputs(spec["sources"], spec.get("smart", False), spec.get("reset", False)) if "sources" in spec
              else fixture_inputs(recipe))
    if inputs:
        (audit / "base-inputs.lua").write_text(inputs)
    config = {"scenario": name, "expectedPanels": spec["expected"], "phases": spec["phases"],
              "fullscreen": spec.get("fullscreen", False),
              "baseInputs": bool(inputs), "swing": 0.4,
              "toggleSwitches": spec.get("toggleSwitches", spec["recipe"] == "state"),
              "toggleLink": spec.get("toggleLink", False),
              "logEntries": spec.get("logEntries", 0), "diagnosticsSources": spec.get("diagnosticsSources", 0),
              "failOnError": True, "traceLimit": 300}
    if spec.get("constructionKind"):
        config["constructionKind"] = spec["constructionKind"]
    if spec.get("reflowKind"):
        config["reflowKind"] = spec["reflowKind"]
    if spec.get("expectedError"):
        config["expectedError"] = spec["expectedError"]
    if name.startswith("lifecycle-"):
        config["progress"] = 1
    if "loops" in spec:
        config["loops"] = spec["loops"]
    (audit / "config.lua").write_text("return " + lua_literal(config) + "\n")
    for file in ("probe.lua", "inputs.lua"):
        shutil.copyfile(PROBE_DIR / file, audit / file)
    if spec.get("constructionParity"):
        for file in ("construction_cases.lua", "panel_tree.lua", "native_construction.lua",
                     "native_construction_cost.lua", "native_rx_reflow.lua",
                     "reflow_cases.lua", "native_panel_reflow.lua"):
            shutil.copyfile(SUPPORT_DIR / file, audit / file)
    if spec.get("preparation"):
        shutil.copyfile(SUPPORT_DIR / "native_preparation.lua", audit / "native_preparation.lua")


def run(capture, executable, library, name, spec, timeout, mode="legacy"):
    directory = OUTPUT / (name if mode == "legacy" else f"{name}-{mode}")
    if directory.exists():
        shutil.rmtree(directory)
    directory.mkdir(parents=True)
    sd = directory / "sdcard"
    prepare(capture, name, spec, sd, mode)
    command = [str(executable), str(library), str(sd), str(timeout)]
    if name.endswith("-firmware"):
        command.append("passthrough")
    if spec.get("fullscreen"):
        command.append("fullscreen")
    with (directory / "simulator.log").open("w") as log:
        result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=timeout + 30)
    results = sd / "audit-results.json"
    if result.returncode != 0 or not results.exists():
        raise RuntimeError(f"{name}: native run failed; inspect {directory / 'simulator.log'}")
    data = json.loads(results.read_text())
    if data.get("errors"):
        raise RuntimeError(f"{name}: widget errors: {data['errors']}")
    if spec.get("lifecycleDrain"):
        if not any(label.startswith("lifecycle:retirePage:settings:save_") for label in data.get("stats", {})):
            raise RuntimeError(f"{name}: missing complete active settings-drain atom")
    if spec.get("lifecycleMenuClose"):
        if not data.get("stats", {}).get("lifecycle:retirePage:menu", {}).get("n"):
            raise RuntimeError(f"{name}: missing complete actual menu-close atom")
    if spec.get("preparation"):
        matrix = data.get("preparation", {})
        if not matrix.get("done") or matrix.get("checked") != matrix.get("total") or not matrix.get("checked"):
            raise RuntimeError(f"{name}: native preparation matrix was not completed")
        for kind in ("metric", "chart", "state"):
            for prefix in ("load:panel-prepare", "lifecycle:advanceAppRebuild:prepare"):
                if not any(label.startswith(f"{prefix}:{kind}:settings:validation")
                           for label in data.get("stats", {})):
                    raise RuntimeError(f"{name}: missing complete preparation measurement for {kind}")
        for panel in (WIDGET / "panels").glob("*.lua"):
            for prefix in ("load:panel-prepare", "lifecycle:advanceAppRebuild:prepare"):
                if not data.get("stats", {}).get(f"{prefix}:{panel.stem}:module", {}).get("n"):
                    raise RuntimeError(f"{name}: missing complete module preparation for {panel.stem}")
    if spec.get("constructionParity"):
        matrix = data.get("construction", {})
        if not matrix.get("done") or matrix.get("checked", 0) != matrix.get("total") or not matrix.get("checked"):
            raise RuntimeError(f"{name}: native construction matrix was not completed")
        if name.startswith("construction-cost"):
            kinds = [spec["constructionKind"]] if spec.get("constructionKind") else [
                "metric", "link-status", "rx-battery", "tx-battery", "flight-timer"]
            for kind in kinds:
                for label in (f"load:panel-build:{kind}", f"lifecycle:advanceAppRebuild:build:{kind}"):
                    if not data.get("stats", {}).get(label, {}).get("n"):
                        raise RuntimeError(f"{name}: missing complete construction measurement for {label}")
        if name in ("rx-reflow-matrix", "rx-reflow-cost"):
            for stage in ("begin", "fit", "place"):
                label = f"lifecycle:advanceReflow:rx-battery:{stage}"
                if not data.get("stats", {}).get(label, {}).get("n"):
                    raise RuntimeError(f"{name}: missing complete reflow measurement for {label}")
        if spec.get("reflowKind"):
            recorded = name.startswith("reflow-matrix-")
            if matrix.get("recordingTrees") != recorded or matrix.get("costOnly") != (not recorded):
                raise RuntimeError(f"{name}: native tree recording and pure cost provenance disagree")
            prefix = ("recorded:" if recorded else "") + \
                f"lifecycle:advanceReflow:{spec['reflowKind']}:"
            for stage in REFLOW_STAGES[spec["reflowKind"]]:
                if not data.get("stats", {}).get(prefix + stage, {}).get("n"):
                    raise RuntimeError(f"{name}: missing complete reflow measurement for {prefix + stage}")
    actions = [phase["action"] for phase in spec["phases"] if phase.get("action")]
    for action in set(actions):
        samples = data.get("stats", {}).get(f"callback:action:{action}", {}).get("n", 0)
        if samples != actions.count(action):
            raise RuntimeError(f"{name}: missing timed action callbacks for {action}")
    (directory / "results.json").write_text(json.dumps(data, indent=1) + "\n")
    return data


def prepare_framework(capture, sd, cases):
    """An isolated image whose widget only runs the framework measurements."""
    prepare(capture, "framework", {"recipe": "metric", "placements": {"subject": (0, 0, 1, 1)}, "expected": 1,
                                   "baseInputs": True, "phases": []}, sd)
    widget = sd / "WIDGETS/AeroGrid"
    audit = widget / "audit"
    shutil.copyfile(PROBE_DIR / "framework-main.lua", widget / "main.lua")
    shutil.copyfile(WIDGET / "panels/chart.lua", widget / "panels/chart.lua")
    shutil.copyfile(PROBE_DIR / "framework.lua", audit / "framework.lua")
    for name in ("scheduler_overhead.lua", "scheduler_measure.lua", "scheduler_mixes.lua",
                 "scheduler_panel_api.lua", "scheduler_chart_fixture.lua", "scheduler_flight_readout.lua",
                 "scheduler_probe_fixture.lua", "scheduler_diagnostics_fixture.lua", "scheduler_flight_fixture.lua",
                 "theme_resolution_fixture.lua", "scheduler_registration_fixture.lua", "memory_files.lua",
                 "construction_cases.lua", "scheduler_broker_registration.lua"):
        shutil.copyfile(SUPPORT_DIR / name, audit / name)
    (audit / "cases").mkdir()
    for case in cases:
        shutil.copyfile(case, audit / "cases" / case.name)
    (audit / "config.lua").write_text("return " + lua_literal({"cases": [case.stem for case in cases]}) + "\n")


def run_framework(capture, executable, library, cases, timeout):
    directory = OUTPUT / "framework"
    if directory.exists():
        shutil.rmtree(directory)
    directory.mkdir(parents=True)
    sd = directory / "sdcard"
    prepare_framework(capture, sd, cases)
    with (directory / "simulator.log").open("w") as log:
        result = subprocess.run([str(executable), str(library), str(sd), str(timeout)], stdout=log,
                                stderr=subprocess.STDOUT, timeout=timeout + 30)
    results = sd / "audit-results.json"
    if result.returncode != 0 or not results.exists():
        error = sd / "audit-error.txt"
        raise RuntimeError(f"framework: native run failed; {error.read_text().strip() if error.exists() else ''}"
                           f" inspect {directory / 'simulator.log'}")
    data = json.loads(results.read_text())
    (directory / "results.json").write_text(json.dumps(data, indent=1) + "\n")
    return data


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("scenario", nargs="*", help="Scenario names; omit with --list or --all")
    parser.add_argument("--all", action="store_true")
    parser.add_argument("--list", action="store_true")
    parser.add_argument("--framework", nargs="*", metavar="CASE", help=f"Measure the scheduler framework's own cost "
                        f"and the case files in {CASE_DIR.relative_to(ROOT)} (all, or the names given)")
    parser.add_argument("--report", action="store_true", help="Summarize the results already in build/scheduler-audit")
    parser.add_argument("--timeout", type=int, default=900, help="Seconds before a native run is abandoned")
    parser.add_argument("--traces", action="store_true", help=f"Copy callback traces to {TRACE_DIR}")
    parser.add_argument("--mode", choices=("legacy", "mixed"), default="mixed",
                        help="Run migrated tasks in mixed mode, or use legacy mode as a baseline for remaining tasks")
    parser.add_argument("--companion", type=Path, default=COMPANION)
    args = parser.parse_args()
    available = scenarios()
    if args.framework is not None:
        cases = sorted(CASE_DIR.glob("*.lua"))
        if args.framework:
            cases = [CASE_DIR / f"{name}.lua" for name in args.framework]
        missing = [case.name for case in cases if not case.is_file()]
        if missing:
            parser.error(f"Unknown case files: {missing}")
        if platform.system() != "Darwin":
            parser.error("This measurement requires macOS and the EdgeTX Companion 2.12 simulator.")
        library = args.companion / "Contents/Resources/libedgetx-tx16s-simulator.dylib"
        if not library.is_file():
            parser.error(f"Simulator library not found: {library}")
        ok, lines = framework_report(run_framework(capture_module(), build_native(library), library, cases, args.timeout))
        print("\n".join(lines))
        return 0 if ok else 1
    if args.report:
        runs = {path.parent.name: json.loads(path.read_text()) for path in sorted(OUTPUT.glob("*/results.json"))
                if "stats" in json.loads(path.read_text()) and not path.parent.name.endswith("-mixed")}
        status = 0
        pair = [OUTPUT / name / "results.json" for name in ("hook-check", "hook-check-firmware")]
        if all(path.exists() for path in pair):
            ok, message = hook_check_status(*(json.loads(path.read_text()) for path in pair))
            print(message, file=sys.stdout if ok else sys.stderr)
            status = 0 if ok else 1
        print("task\tcalls\tmean\tmax\tself_max\tunits\tper_unit\tscenario")
        for label, row in sorted(aggregate(runs).items()):
            print(f"{label}\t{row['n']}\t{row['mean']}\t{row['max']}\t{row['selfMax']}\t{row['maxUnits']}\t{row['perUnit']}\t{row['scenario']}")
        return status
    if args.list:
        print("\n".join(available))
        return 0
    names = list(available) if args.all else args.scenario
    unknown = [name for name in names if name not in available]
    if not names or unknown:
        parser.error(f"Choose scenarios from --list; unknown: {unknown}")
    if platform.system() != "Darwin":
        parser.error("This audit requires macOS and the EdgeTX Companion 2.12 simulator.")
    library = args.companion / "Contents/Resources/libedgetx-tx16s-simulator.dylib"
    if not library.is_file():
        parser.error(f"Simulator library not found: {library}")
    executable = build_native(library)
    capture = capture_module()
    checks = {}
    status = 0
    for name in names:
        data = run(capture, executable, library, name, available[name], args.timeout, args.mode)
        if "loops" in available[name]:
            checks[name] = data
            if len(checks) == 2:
                ok, message = hook_check_status(checks["hook-check"], checks["hook-check-firmware"])
                print(message, file=sys.stdout if ok else sys.stderr)
                status = status or (0 if ok else 1)
            continue
        rows = reduce_results(data)
        worst = max((row["max"] for label, row in rows.items() if label.startswith("callback:")), default=0)
        print(f"{name} ({args.mode}): {data['panels']} panels, worst callback {worst} instructions, "
              f"{len(rows)} measured tasks")
        if args.traces and data["trace"] and available[name].get("trace"):
            TRACE_DIR.mkdir(parents=True, exist_ok=True)
            (TRACE_DIR / f"{name}.txt").write_text("\n".join(data["trace"]) + "\n")
    return status


if __name__ == "__main__":
    sys.exit(main())

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
import shutil
import subprocess
import sys

TOOLS = Path(__file__).resolve().parent
sys.path.insert(0, str(TOOLS))
from scheduler_audit import (CASE_DIR, PROBE_DIR, ROOT, SUPPORT_DIR, WIDGET, lua_literal, patch_chart,  # noqa: E402
                             patch_loader, patch_main, aggregate, framework_report, hook_check_status,
                             reduce_results, supported_spans)
from capture_recipes import PANELS, RECIPE_DIR, fixture_inputs, load_recipe  # noqa: E402

OUTPUT = ROOT / "build/scheduler-audit"
COMPANION = Path("/Applications/EdgeTX Companion 2.12.app")
TRACE_DIR = ROOT / "tests/fixtures/scheduler-traces"
MODEL_SETTINGS = "version: 1\nmodelFilename: model1.yml\nrevision: 1\narmed: SAv\n"


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
for index, source in ipairs(sources) do
    source.field = 30000 + index
end
local armIndex = assert(getSwitchIndex("SA" .. CHAR_DOWN))
local resetIndex = {reset_index}
local function find(key)
    for _, source in ipairs(sources) do
        if source.field == key or source.name == key then return source end
    end
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
    result["flight-smart"] = {
        "recipe": "metric", "expected": 2, "sources": 3, "settings": True, "smart": True,
        "layout": custom_layout([chart_cell("chart-a", 0, 2, (1, 2, 3)),
                                 "  - id: counter\n    type: flight-counter\n    col: 0\n    row: 2\n"
                                 "    colSpan: 2\n    rowSpan: 1\n    config:\n      armSwitch: SAv\n"]),
        "phases": standard_phases(refreshes=800),
    }
    result["session-reset"] = {
        "recipe": "metric", "expected": 2, "sources": 6, "settings": True, "reset": True,
        "layout": custom_layout([chart_cell("chart-a", 0, 2, (1, 2, 3)),
                                 metric_cell(1, (4, 5, 6)).replace("row: 0", "row: 2")]),
        "phases": standard_phases(refreshes=800),
    }
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


def prepare(capture, name, spec, sd):
    recipe_path = RECIPE_DIR / f"{spec['recipe']}.yaml"
    recipe = load_recipe(recipe_path)
    if "placements" in spec:
        recipe["panels"] = {key: {"col": col, "row": row, "colSpan": cs, "rowSpan": rs}
                            for key, (col, row, cs, rs) in spec["placements"].items()}
    recipe["config"].update(spec.get("config", {}))
    capture.prepare(sd, recipe, recipe_path)
    widget = sd / "WIDGETS/AeroGrid"
    audit = widget / "audit"
    audit.mkdir()
    # Capture's own readiness hooks are replaced; start again from the shipped sources.
    shutil.copyfile(WIDGET / "main.lua", widget / "main.lua")
    shutil.copyfile(WIDGET / "lib/dashboard_loader.lua", widget / "lib/dashboard_loader.lua")
    (widget / "main.lua").write_text(patch_main((WIDGET / "main.lua").read_text()))
    (widget / "lib/dashboard_loader.lua").write_text(patch_loader((WIDGET / "lib/dashboard_loader.lua").read_text()))
    (widget / "panels/chart.lua").write_text(patch_chart((WIDGET / "panels/chart.lua").read_text()))
    if "layout" in spec:
        (widget / "layouts/capture-panels.yaml").write_text(spec["layout"])
    if spec.get("settings"):
        settings = sd / "AEROGRID/models"
        settings.mkdir(parents=True, exist_ok=True)
        (settings / ("model1.yml".encode().hex() + ".yaml")).write_text(
            MODEL_SETTINGS + ("sessionReset: SBv\n" if spec.get("reset") else "")
            + ("flight:\n  smartDetection: true\n  minFlightDuration: 1\n  disarmDuration: 3\n"
               if spec.get("smart") else ""))
    inputs = (synthetic_inputs(spec["sources"], spec.get("smart", False), spec.get("reset", False)) if "sources" in spec
              else fixture_inputs(recipe))
    if inputs:
        (audit / "base-inputs.lua").write_text(inputs)
    config = {"scenario": name, "expectedPanels": spec["expected"], "phases": spec["phases"],
              "baseInputs": bool(inputs), "swing": 0.4, "toggleSwitches": spec["recipe"] == "state",
              "failOnError": True, "traceLimit": 300}
    if "loops" in spec:
        config["loops"] = spec["loops"]
    (audit / "config.lua").write_text("return " + lua_literal(config) + "\n")
    for file in ("probe.lua", "inputs.lua"):
        shutil.copyfile(PROBE_DIR / file, audit / file)


def run(capture, executable, library, name, spec, timeout):
    directory = OUTPUT / name
    if directory.exists():
        shutil.rmtree(directory)
    directory.mkdir(parents=True)
    sd = directory / "sdcard"
    prepare(capture, name, spec, sd)
    command = [str(executable), str(library), str(sd), str(timeout)]
    if name.endswith("-firmware"):
        command.append("passthrough")
    with (directory / "simulator.log").open("w") as log:
        result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=timeout + 30)
    results = sd / "audit-results.json"
    if result.returncode != 0 or not results.exists():
        raise RuntimeError(f"{name}: native run failed; inspect {directory / 'simulator.log'}")
    data = json.loads(results.read_text())
    if data.get("errors"):
        raise RuntimeError(f"{name}: widget errors: {data['errors']}")
    (directory / "results.json").write_text(json.dumps(data, indent=1) + "\n")
    return data


def prepare_framework(capture, sd, cases):
    """An isolated image whose widget only runs the framework measurements."""
    prepare(capture, "framework", {"recipe": "metric", "placements": {"subject": (0, 0, 1, 1)}, "expected": 1,
                                   "baseInputs": True, "phases": []}, sd)
    widget = sd / "WIDGETS/AeroGrid"
    audit = widget / "audit"
    shutil.copyfile(PROBE_DIR / "framework-main.lua", widget / "main.lua")
    shutil.copyfile(PROBE_DIR / "framework.lua", audit / "framework.lua")
    for name in ("scheduler_overhead.lua", "scheduler_measure.lua", "scheduler_mixes.lua"):
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
                if "stats" in json.loads(path.read_text())}
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
        data = run(capture, executable, library, name, available[name], args.timeout)
        if "loops" in available[name]:
            checks[name] = data
            if len(checks) == 2:
                ok, message = hook_check_status(checks["hook-check"], checks["hook-check-firmware"])
                print(message, file=sys.stdout if ok else sys.stderr)
                status = status or (0 if ok else 1)
            continue
        rows = reduce_results(data)
        worst = max((row["max"] for label, row in rows.items() if label.startswith("callback:")), default=0)
        print(f"{name}: {data['panels']} panels, worst callback {worst} instructions, {len(rows)} measured tasks")
        if args.traces and data["trace"] and available[name].get("trace"):
            TRACE_DIR.mkdir(parents=True, exist_ok=True)
            (TRACE_DIR / f"{name}.txt").write_text("\n".join(data["trace"]) + "\n")
    return status


if __name__ == "__main__":
    sys.exit(main())

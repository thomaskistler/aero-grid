# SPDX-License-Identifier: GPL-2.0-only
"""Opt-in chart experiments, not a production renderer or a full gate pass."""

import argparse
import importlib.util
import json
import re
import struct
from array import array
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]


def mock(output, kernel, recorded=False, batch=130, profile=False, sample_ticks=20, stress=False):
    from lupa.lua53 import LuaRuntime

    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute('debug.setmetatable("", nil)')
    if stress:
        rows = lua.execute(
            (ROOT / "tests/experiments/chart_mipmap_stress_mock.lua").read_text(),
            str(ROOT), batch,
        )
        results = [dict(rows[index].items()) for index in range(1, len(rows) + 1)]
        for row in results:
            row["callback_instructions"] = list(row["callback_instructions"].values())
            row["passed"] = (
                len(row["callback_instructions"]) == row["callbacks"]
                and all(count < 15000 for count in row["callback_instructions"])
                and row["setter_complete_ms"] < (500 if row["operation"] in ("append", "scroll") else 1001)
                and row["turns"] <= (2 if row["operation"] in ("append", "scroll") else 5)
            )
        limits_passed = len(results) == 5 and all(row["passed"] for row in results)
        report = {
            "kind": "mock continuous 2-chart/800-column/3-series/24-source/Smart workload",
            "results": results,
            "workload_limits_passed": limits_passed,
            "gate_passed": False,
            "limitations": [
                "Mock Lua setter bodies inflate instruction counts; no native painting measurement.",
                "Input continues through both initial redraws; verification fences and drains the received readings.",
            ],
        }
        (output / "mock-results.json").write_text(json.dumps(report, indent=2) + "\n")
        return limits_passed
    rows = lua.execute(
        (ROOT / "tests/experiments/chart_feasibility.lua").read_text(),
        str(ROOT),
        kernel,
        recorded,
        None,
        batch,
        profile,
        sample_ticks,
    )
    results = [dict(rows[index].items()) for index in range(1, len(rows) + 1)]
    for row in results:
        row["component_profile"] = {
            stage: dict(cost.items()) for stage, cost in row["component_profile"].items()
        }
    accumulation = None if recorded else lua.execute(
        (ROOT / "tests/experiments/chart_accumulation_feasibility.lua").read_text(),
    )
    report = {
        "kind": "mock incoming-reading mipmap with real recorder" if recorded else "mock min/max vertical-column warm-pool workload",
        "drawing_results": results,
        "accumulation_lower_bound": dict(accumulation.items()) if accumulation is not None else None,
        "limitations": [
            "No native painting-time measurement.",
            "12 simple overlays, no full gap/flight/Smart workload in synthetic drawing.",
            "Resize point remapping only, no resize layout or complete mipmap maintenance.",
            "Warm allocations; one native vline per non-gap column; not a complete renderer.",
            "160 ms host callbacks; multiple charts receive serialized subsets of them.",
            "Counts include the mock's Lua setter body; firmware setters run in C++.",
            "Isolated kernels exclude complementary work and cannot pass the full gate.",
        ],
        "gate_passed": False,
    }
    if recorded:
        report["limitations"] = [
            "Real recorder and hierarchy, plus current host service/dispatch work; not 24-source/Smart stress.",
            "Mock Lua setters inflate counts compared with the native C++ API.",
            "One native pool, in-place redraws; no atomic replacement frame or full resize layout.",
            "Warm initialization excluded; source updates occur at operation admission, not continuous polling.",
            "No per-operation painted-frame measurement; no shared consumers, preview or rolling-chart wiring.",
            "Configured 1/2/5-turn limits remain enforced even when bounded work takes longer.",
            "Recording stage includes synchronous filtered-reading observers; maintenance means deferred work only.",
            "Fixed-level scroll starts from a populated maximum-level window; preparation is outside timing.",
        ]
        if profile:
            report["limitations"].append(
                "Component profiles add hook/wrapper/checkpoint overhead. Mock setter body is a subset of drawing, not additive."
            )
    (output / "mock-results.json").write_text(json.dumps(report, indent=2) + "\n")
    return all(row["passed"] for row in results)


def verify_paint(output, sd):
    targets = {}
    for path in sorted(sd.glob("paint-*.txt")):
        if not re.fullmatch(r"paint-\d+\.txt", path.name):
            continue
        lines = path.read_text().splitlines()
        phase, started, submitted = map(int, lines[0].split())
        expected = {}
        region = None

        def color565(color):
            # EdgeTX colors store RGB565 in the upper word, not packed RGB888.
            return color >> 16 & 0xffff

        for line in lines[1:]:
            kind, *values = line.split()
            if kind == "P":
                x, y, width, height, color = map(int, values)
                region = (x, y, x + width, y + height)
                for yy in range(max(0, y), min(272, y + height)):
                    for xx in range(max(0, x), min(480, x + width)):
                        expected[yy * 480 + xx] = color565(color)
            elif kind == "L" and region is not None:
                x, y, height, color = map(int, values)
                if region[0] <= x < region[2] and 0 <= x < 480:
                    for yy in range(max(0, y, region[1]), min(272, y + height, region[3])):
                        expected[yy * 480 + x] = color565(color)
            else:
                raise RuntimeError(f"Malformed paint target: {path}")
        if not expected:
            raise RuntimeError(f"Empty paint target: {path}")
        targets[phase] = {"started": started, "submitted": submitted, "pixels": expected}
    trace = output / "frame.rgb565.trace"
    if not trace.exists():
        return []
    with trace.open("rb") as source:
        while header := source.read(8):
            if len(header) != 8:
                raise RuntimeError("Truncated native framebuffer timestamp")
            phase, stamp = struct.unpack("<II", header)
            data = source.read(480 * 272 * 2)
            if len(data) != 480 * 272 * 2:
                raise RuntimeError("Truncated native framebuffer capture")
            target = targets.get(phase)
            if target and stamp >= target["submitted"] and "painted" not in target:
                pixels = array("H", data)
                if sys.byteorder != "little":
                    pixels.byteswap()
                mismatches = [index for index, color in target["pixels"].items() if pixels[index] != color]
                if len(mismatches) < target.get("mismatches", len(target["pixels"]) + 1):
                    target["mismatches"] = len(mismatches)
                    target["mismatch_examples"] = [{
                        "x": index % 480, "y": index // 480,
                        "expected": target["pixels"][index], "actual": pixels[index],
                    } for index in mismatches[:6]]
                if not mismatches:
                    target["painted"] = stamp
    return [{
        "phase": phase,
        "pixels_checked": len(target["pixels"]),
        "verified": "painted" in target,
        "mismatched_pixels": target.get("mismatches"),
        "mismatch_examples": target.get("mismatch_examples", []),
        "paint_complete_ms": target["painted"] - target["started"] if "painted" in target else None,
        "paint_after_submission_ms": target["painted"] - target["submitted"] if "painted" in target else None,
    } for phase, target in sorted(targets.items())]


def native(output, points, recorded=False, batch=130, sample_ticks=20, series=3, stress=False):
    sys.path.insert(0, str(ROOT / "tools"))
    spec = importlib.util.spec_from_file_location("capture", ROOT / "tools/capture-panels.py")
    capture = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(capture)
    companion = Path("/Applications/EdgeTX Companion 2.12.app")
    library = companion / "Contents/Resources/libedgetx-tx16s-simulator.dylib"
    if not library.is_file():
        raise RuntimeError(f"Native simulator unavailable: {library}")
    architecture = subprocess.check_output(["lipo", "-archs", str(library)], text=True).split()
    if len(architecture) != 1:
        raise RuntimeError("The native experiment requires a single-architecture simulator")
    executable = output / "capture-native"
    capture_source = ROOT / "tools/capture-native.cpp"
    if recorded:
        # Dense maximum-level preparation needs more time, not larger Lua callbacks.
        source = capture_source.read_text()
        if source.count("tick < 3000") != 1:
            raise RuntimeError("Update the experiment's native preparation timeout injection")
        capture_source = output / "capture-native.cpp"
        capture_source.write_text(source.replace("tick < 3000", f"tick < {18000 if stress else 6000}"))
    subprocess.run([
        "clang++", "-std=c++11", "-arch", architecture[0],
        str(capture_source),
        f"-Wl,-rpath,{companion / 'Contents/Frameworks'}", "-o", str(executable),
    ], check=True)
    sd = output / "sdcard"
    if sd.exists():
        raise RuntimeError(f"Choose a fresh output directory; refusing to replace {sd}")
    recipe_path = ROOT / "tools/capture-recipes/chart.yaml"
    recipe = capture.load_recipe(recipe_path)
    span = 2 if points == 240 else 4
    recipe["panels"] = {"full": {"col": 0, "row": 0, "colSpan": span, "rowSpan": span}}
    recipe["config"]["metrics"] = recipe["config"]["metrics"][:series]
    capture.prepare(sd, recipe, recipe_path)
    widget = sd / "WIDGETS/AeroGrid"
    if stress:
        lines = ["version: 5", "grid:", "  columns: 4", "  rows: 4", "panels:"]
        for chart in range(2):
            lines.append(f"  - id: stress{chart + 1}\n    type: chart\n    col: 0\n    row: {chart * 2}\n"
                         "    colSpan: 4\n    rowSpan: 2\n    config:\n      metrics:")
            for channel in range(3):
                lines.append(f"        - source: Q{chart * 3 + channel + 1}\n          precision: 3")
        (widget / "layouts/capture-panels.yaml").write_text("\n".join(lines) + "\n")
        (sd / "AEROGRID/models" / ("model1.yml".encode().hex() + ".yaml")).write_text(
            "version: 1\nmodelFilename: model1.yml\nrevision: 1\narmed: SAv\n")
    (widget / "chart-feasibility-probe.lua").write_text(
        (ROOT / "tests/support/chart_feasibility.lua").read_text()
    )
    if recorded:
        for name in ("chart_mipmap_prototype.lua", "mipmap_recorder.lua", "chart_mipmap_stress.lua"):
            target = widget / "tests/support" / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text((ROOT / "tests/support" / name).read_text())
    driver = (ROOT / "tests/experiments/native_chart_feasibility.lua").read_text()
    if driver.count("points = 512") != 1:
        raise RuntimeError("Update the experiment's native point-count injection")
    (widget / "chart-feasibility-driver.lua").write_text(driver.replace("points = 512", f"points = {points}"))
    if recorded:
        driver = driver.replace("local recorded = false", "local recorded = true").replace(
            "entry.instance, 512", f"entry.instance, {points}"
        ).replace("local batchSize = 130", f"local batchSize = {batch}").replace(
            "local sampleTicks = 20", f"local sampleTicks = {sample_ticks}"
        )
        (widget / "chart-feasibility-driver.lua").write_text(driver)
    if stress:
        driver = (ROOT / "tests/experiments/native_chart_mipmap_stress.lua").read_text()
        (widget / "chart-feasibility-driver.lua").write_text(
            driver.replace("local batchSize = 64", f"local batchSize = {batch}"))
    source = (ROOT / "src/WIDGETS/AeroGrid/main.lua").read_text()
    if source.count("    refresh = refresh,") != 1:
        raise RuntimeError("Update the experiment's isolated refresh injection")
    source = source.replace("    refresh = refresh,", """    refresh = function(context)
        context.feasibilityDriver = context.feasibilityDriver
            or assert(loadScript("/WIDGETS/AeroGrid/chart-feasibility-driver.lua"))()
        return context.feasibilityDriver(context, refresh)
    end,""")
    (widget / "main.lua").write_text(source)
    regions = output / "regions.txt"
    regions.write_text("0 0 480 272\n")
    with (output / "simulator.log").open("w") as log:
        command = [str(executable), str(library), str(sd), str(output / "frame.rgb565"), str(regions)]
        if stress:
            command.append("trace")
        result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=240 if stress else 90)
    results = sd / "chart-feasibility.txt"
    text = results.read_text() if results.exists() else ""
    print(text or "No native results; inspect simulator.log")
    measurements = [
        dict(re.findall(r"(\w+)=(\w+)", line))
        for line in text.splitlines() if line.startswith("op=")
    ]
    completed = (
        result.returncode == 0
        and "FAIL" not in text
        and len(measurements) == 5
        and {row.get("op") for row in measurements} == {"append", "horizontal", "vertical", "scroll", "resize"}
    )
    for row in measurements:
        row["instruction_upper_bound"] = (int(row["usage_percent"]) + 1) * 200
    callback_samples = [
        dict(re.findall(r"(\w+)=(\w+)", line))
        for line in text.splitlines() if line.startswith("TURN ")
    ]
    trace_complete = completed and all(
        [int(sample["turn"]) for sample in callback_samples if sample["op"] == row["op"]]
        == list(range(1, int(row.get("host_callbacks", row["turns"])) + 1))
        for row in measurements
    )
    callback_limits_passed = trace_complete and all(
        (int(sample["usage_percent"]) + 1) * 200 < 15000 for sample in callback_samples
    )
    limits_passed = callback_limits_passed and all(
        row["instruction_upper_bound"] < 15000
        and int(row["setter_complete_ms"]) < (500 if row["op"] in ("append", "scroll") else 1001)
        and int(row["turns"]) <= (1 if row["op"] == "append" and series == 1 else 2 if row["op"] in ("append", "scroll") else 5)
        for row in measurements
    )
    report = {
        "kind": "native incoming-reading mipmap with real recorder" if recorded else "native min/max vertical-column warm-pool workload",
        "columns_per_series": points,
        "native_display_width": 480,
        "series": series,
        "batch_per_series": batch,
        "sample_ticks": 5 if stress else sample_ticks,
        "results": text,
        "capture_exit": result.returncode,
        "workload_completed": completed,
        "measurements": measurements,
        "callback_samples": callback_samples,
        "callback_trace_complete": trace_complete,
        "callback_limits_passed": callback_limits_passed,
        "workload_limits_passed": limits_passed,
        "gate_passed": False,
        "limitations": [
            "Times end at native setter/publication, not each operation's confirmed painted frame.",
            "Final capture confirms a stable framebuffer, not per-operation painting deadlines.",
            "Only one chart and warm pools; no complete mipmap or resize layout/Smart/gap stress.",
            "getUsage reports the previous complete native callback in 200-instruction quanta.",
            "Conversion follows EdgeTX v2.12.0 widgets.cpp and lua_widget.cpp; not a bytecode-exact count.",
        ],
    }
    if stress:
        painting = verify_paint(output, sd)
        report["kind"] = "native continuous 2-chart/800-column/3-series/24-source/Smart workload"
        report["charts"], report["recorded_sources"], report["smart"] = 2, 24, True
        report["paint_measurements"] = painting
        report["paint_verified"] = len(painting) == 5 and all(row["verified"] for row in painting)
        report["live_input_covered"] = completed and all(int(row["input_events"]) > 0 for row in measurements)
        limits_passed = limits_passed and report["live_input_covered"] and report["paint_verified"] and all(
            row["paint_complete_ms"] < (500 if row["phase"] in (1, 4) else 1001)
            for row in painting
        )
        report["workload_limits_passed"] = limits_passed
        report["limitations"] = [
            "Both charts contain 800 columns and three series on the 480-pixel native simulator.",
            "Real polling/recording/Smart/dispatcher path with deterministic synthetic firmware values.",
            "Triggers align with a natural chart-source poll; no poll quota, cursor or service-order override.",
            "Input continues throughout competing initial redraws; a comparison fence then drains received samples. Polling and recording are not paused.",
            "Native framebuffer trace verifies all expected plot pixels, including cleared/gap regions.",
            "Warm/preparation and bounded diagnostic target export are outside timed submission callbacks.",
            "One pool per chart; no atomic staged replacement, actual layout resize, production ownership or hardware heap approval.",
        ]
    if recorded and not stress:
        report["limitations"] = [
            "Actual recorder, eleven prepared levels and retirement, with host services; not 24-source/Smart stress.",
            "One warm pool, in-place redraws; no atomic replacement frame or full resize layout.",
            "Source update at each operation admission; not a continuous-input or painted-frame latency test.",
            f"{points}-column workload on a 480-pixel simulator, not MK3 hardware/display validation.",
            "No multi-consumer, preview or rolling-chart integration; production renderer remains unchanged.",
            "getUsage is previous complete callback usage in 200-instruction quanta, not an exact bytecode count.",
            "Incoming-reading hierarchy updates are included in admission; work=0 means no deferred maintenance.",
            "Fixed-level scroll starts from a populated maximum-level window; preparation is outside timing.",
        ]
    (output / "native-results.json").write_text(json.dumps(report, indent=2) + "\n")
    return limits_passed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--native", action="store_true")
    parser.add_argument("--stress", action="store_true", help="Continuous worst-case charts with real 24-source recording and Smart")
    parser.add_argument("--recorded", action="store_true", help="Exercise incoming-reading hierarchy alongside actual recording")
    parser.add_argument("--batch", type=int, help="Upper limit on recorder-backed columns per series per turn")
    parser.add_argument("--profile", action="store_true", help="Instrument mock recorder-backed stage and setter-body costs")
    parser.add_argument("--sample-ticks", type=int, default=20, choices=(5, 10, 20), help="Warm-up reading spacing in 10ms ticks")
    parser.add_argument("--kernel", choices=("combined", "mapping", "setters"), default="combined")
    parser.add_argument("--columns", "--points", dest="points", type=int, choices=(128, 240, 512, 600, 800))
    parser.add_argument("--series", type=int, default=3, choices=(1, 2, 3), help="Native series count")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.batch = args.batch if args.batch is not None else 64 if args.stress else 130
    args.points = args.points if args.points is not None else 800 if args.stress else 600
    if args.stress and (not args.recorded or args.points != 800 or args.series != 3 or args.profile):
        parser.error("--stress requires --recorded, 800 columns, three series and no --profile")
    if args.batch < 1:
        parser.error("--batch must be positive")
    if args.profile and (not args.recorded or args.native):
        parser.error("--profile requires --recorded without --native")
    if not args.native and args.series != 3:
        parser.error("--series configures native runs only; mock runs include the two-series panel scenario")
    output = args.output.resolve()
    if not output.is_relative_to(ROOT / "build"):
        parser.error("Output must be inside this checkout's build directory")
    output.mkdir(parents=True, exist_ok=True)
    if args.native and args.kernel != "combined":
        parser.error("Native runner currently supports the combined kernel only")
    if args.recorded and args.kernel != "combined":
        parser.error("--recorded requires --kernel combined")
    completed = native(output, args.points, args.recorded, args.batch, args.sample_ticks, args.series, args.stress) if args.native else mock(output, args.kernel, args.recorded, args.batch, args.profile, args.sample_ticks, args.stress)
    print("Workload limits:", "PASS (not a full gate pass)" if completed else "FAIL; full implementation remains blocked")
    return 0 if completed else 1


if __name__ == "__main__":
    raise SystemExit(main())

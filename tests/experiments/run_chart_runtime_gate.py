# SPDX-License-Identifier: GPL-2.0-only
"""Native callback, correctness and latency gate for the default chart runtime."""

import argparse
import json
from pathlib import Path

from run_chart_feasibility import ROOT, native


INPUT_FIELDS = (
    "trace_version", "op", "trigger", "seed_end", "seed_step", "prefix_samples",
    "prefix_hash", "prefix_break_hash", "events", "event_hash", "event_break_hash",
    "input_batches", "period_ms", "sources", "columns",
)


def input_signature(report):
    rows = report.get("measurements", [])
    if report.get("workload_completed") is not True or len(rows) != 1:
        raise ValueError("Frozen workload did not complete")
    row = rows[0]
    if any(field not in row for field in INPUT_FIELDS):
        raise ValueError("Missing frozen-input fingerprint fields")
    if row["trace_version"] != "2" or row["input_batches"] != "4" or row["events"] != "24":
        raise ValueError("Incomplete or unsupported input trace")
    return {field: row[field] for field in INPUT_FIELDS}

# Measured current-gate baseline from chart PR #192 (17eeaa6, 71/63/41).
PAINTED_LATENCY_CEILINGS_MS = {
    "append": 940,
    "horizontal": 2620,
    "vertical": 1500,
    "scroll": 2210,
}


def painted_latency_passes(operation, elapsed_ms):
    return (
        isinstance(elapsed_ms, (int, float))
        and not isinstance(elapsed_ms, bool)
        and 0 <= elapsed_ms <= PAINTED_LATENCY_CEILINGS_MS[operation]
    )


def cases(extended=False):
    result = [(operation, operation, {}) for operation in
              ("append", "horizontal", "vertical", "scroll", "continuous")]
    result += [("rolling", "rolling", {}), ("late-attach", "late-attach", {})]
    if extended:
        result += [
            ("horizontal-level4", "horizontal", {"expansionLevel": 4}),
            ("horizontal-level9", "horizontal", {"expansionLevel": 9}),
            ("scroll-lap2", "scroll", {"scrollLap": 2.25}),
            ("scroll-lap4", "scroll", {"scrollLap": 4.25}),
            ("horizontal-width368", "horizontal", {"widthReduction": 30}),
            ("scroll-width226", "scroll", {"widthReduction": 172}),
            ("live-resize-resume", "lifecycle", {}),
            ("long-flight", "long-flight", {}),
        ]
    return result


def controlled_source(driver, operation, settings):
    source = driver.replace('local operation = "append"', f'local operation = "{operation}"')
    defaults = {"expansionLevel": 0, "scrollLap": 1.25, "widthReduction": 0}
    for name, value in settings.items():
        marker = f"local {name} = {defaults[name]}"
        if source.count(marker) != 1:
            raise ValueError(f"Missing unique fixture setting: {name}")
        source = source.replace(marker, f"local {name} = {value}")
    return source


def report_passes(report, painted, operation):
    return (
        report.get("workload_completed") is True
        and report.get("callback_trace_complete") is True
        and bool(report.get("callback_samples"))
        and all((value + 1) * 200 < 16000 for value in report["callback_samples"])
        and (
            not painted
            or (
                report.get("paint", {}).get("verified") is True
                and report["paint"].get("mismatched_pixels") == 0
                and painted_latency_passes(operation, report["paint"].get("paint_complete_ms"))
            )
        )
    )


def coverage_passes(report, operation):
    if operation == "rolling":
        return report.get("coverage") == [{
            "rolling": "1", "fixed_span": "6000", "scrolled": "1", "sole_renderer": "1",
        }]
    if operation == "late-attach":
        profile, timing = report.get("phase_profile"), report.get("late_attach")
        return (
            report.get("coverage") == [{
                "late_attach": "1", "rebuilt": "1", "retained_history": "1", "sole_renderer": "1",
            }]
            and profile
            and profile.get("rebuild", 0) > 0
            and profile.get("renderer_setup", 0) > 0
            and timing
            and 0 <= timing.get("attach_to_publish_ms", 105000) < 105000
            and timing.get("attach_to_publish_callbacks", 0) > 0
            and timing.get("callbacks", 0) > 0
        )
    if operation != "long-flight":
        return True
    return report.get("coverage") == [{
        "levels": "11", "scrolls_per_series": "6", "logical_step": "50",
        "admission_ms": "50", "uninterrupted": "1", "retired_levels_per_series": "10",
    }]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--extended", action="store_true", help="Also gate higher levels, later scroll laps and resized widths")
    parser.add_argument("--case", choices=[name for name, _, _ in cases(True)],
                        help="Run one case instead of the full gate")
    args = parser.parse_args()
    output = args.output.resolve()
    if not output.is_relative_to(ROOT / "build"):
        parser.error("Output must be inside this checkout's build directory")
    if output.exists():
        parser.error("Choose a fresh output directory")
    output.mkdir(parents=True)
    driver = (ROOT / "tests/experiments/native_chart_mipmap_operations.lua").read_text(encoding="ascii")
    reports = {}
    selected = [case for case in cases(True) if case[0] == args.case] if args.case else cases(args.extended)
    for name, operation, settings in selected:
        target = output / name
        target.mkdir()
        continuous = operation in ("continuous", "lifecycle", "long-flight", "rolling", "late-attach")
        if operation in ("lifecycle", "long-flight", "rolling", "late-attach"):
            source = (ROOT / "tests/experiments/native_chart_mipmap_integrated.lua").read_text(encoding="ascii")
            marker = {"lifecycle": "lifecycle", "long-flight": "longFlight",
                      "rolling": "rolling", "late-attach": "lateAttach"}[operation]
            source = source.replace(f"local {marker} = false", f"local {marker} = true")
        else:
            source = None if continuous else controlled_source(driver, operation, settings)
        native(
            target, 800, True, 73, 20, 3, True, False,
            integrated=continuous, matched=None if continuous else "integrated",
            runtime_source=True, controlled_driver=source,
            arm_switch="SAv" if operation == "lifecycle" else None,
            long_run=operation in ("long-flight", "lifecycle", "late-attach"),
            chart_time_range="rolling" if operation == "rolling" else None,
            framebuffer_trace=not continuous,
            instruction_limit=16000,
        )
        report = json.loads((target / "native-results.json").read_text())
        report["kind"] = (
            f"default chart native {operation} callback smoke" if continuous
            else f"default chart native {operation}: full-panel input-derived reference comparison"
        )
        report.pop("allowance", None)
        report["quota_policy"] = "Unmodified repository chart runtime; no allowance injection."
        report["runtime_modules_unmodified"] = {
            path: (target / "sdcard/WIDGETS/AeroGrid" / path).read_bytes()
            == (ROOT / "src/WIDGETS/AeroGrid" / path).read_bytes()
            for path in ("panels/chart.lua", "lib/chart_mipmap.lua",
                         "lib/chart_mipmap_renderer.lua", "lib/history_service.lua")
        }
        loader = (target / "sdcard/WIDGETS/AeroGrid/lib/dashboard_loader.lua").read_text()
        override = 'support.environment(assert(loadScript("/WIDGETS/AeroGrid/capture-inputs.lua"))())'
        report["loader_input_override_verified"] = (
            loader.count(override) == 1
            and loader.replace(override, "support.environment()")
            == (ROOT / "src/WIDGETS/AeroGrid/lib/dashboard_loader.lua").read_text()
        )
        report["runtime_source_unmodified"] = all(report["runtime_modules_unmodified"].values())
        report["input_signature"] = None if continuous else input_signature(report)
        passed = (
            report_passes(report, painted=not continuous, operation=operation)
            and report["runtime_source_unmodified"]
            and report["loader_input_override_verified"]
            and coverage_passes(report, operation)
        )
        reports[name] = {
            "passed": passed,
            "painted_latency_ceiling_ms": None if continuous else PAINTED_LATENCY_CEILINGS_MS[operation],
            "instruction_upper_bound": report["instruction_upper_bound"],
            "paint": report.get("paint"),
            "measurements": report["measurements"],
            "phase_profile": report.get("phase_profile"),
            "late_attach": report.get("late_attach"),
            "fixture_settings": settings,
            "input_signature": report["input_signature"],
            "coverage": report.get("coverage", []),
        }
        report["runtime_callback_gate_passed"] = passed
        report["limitations"] = [
            "Default runtime loads its own mipmap dependencies; panel, history, mipmap and renderer sources are unchanged.",
            "Loader differs only by its verified deterministic input-environment override; refresh wrapper and clocks are diagnostic.",
            "Controlled v1 cases reset history at a fixed epoch and replay a fixed prefix plus four six-source batches.",
            "Those six chart sources reject service-driven samples; telemetry/Smart and other sources remain active.",
            "Frozen-trace timings are not directly comparable to the old completion-dependent baseline ceilings.",
            "Controlled complete paint must not exceed the measured 17eeaa6 baseline: "
            "append 940ms, horizontal 2620ms, vertical 1500ms, scroll 2210ms.",
            "Paint references retain normal overlays, not an independent overlay-algorithm oracle.",
            "This gate covers native callback instructions and controlled pixels, not hardware memory or release acceptance.",
        ]
        if operation == "long-flight":
            report["limitations"].append(
                "Long flight advances 50 logical ticks per 50ms admission (10x); services acquire every sample "
                "without replay or observer fences. Logical sample density differs from a real-time flight."
            )
        (target / "native-results.json").write_text(json.dumps(report, indent=2) + "\n")
    passed = all(report["passed"] for report in reports.values())
    summary = {"passed": passed, "operations": reports}
    (output / "runtime-gate.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary, indent=2))
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())

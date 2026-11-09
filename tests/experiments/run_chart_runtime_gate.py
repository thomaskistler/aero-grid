# SPDX-License-Identifier: GPL-2.0-only
"""Native callback/correctness gate for the actual opt-in chart runtime."""

import argparse
import json
from pathlib import Path

from run_chart_feasibility import ROOT, native


def report_passes(report, painted):
    return (
        report.get("workload_completed") is True
        and report.get("callback_trace_complete") is True
        and bool(report.get("callback_samples"))
        and all((value + 1) * 200 < 15000 for value in report["callback_samples"])
        and (
            not painted
            or (
                report.get("paint", {}).get("verified") is True
                and report["paint"].get("mismatched_pixels") == 0
                and report["paint"].get("paint_complete_ms") is not None
            )
        )
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    output = args.output.resolve()
    if not output.is_relative_to(ROOT / "build"):
        parser.error("Output must be inside this checkout's build directory")
    if output.exists():
        parser.error("Choose a fresh output directory")
    output.mkdir(parents=True)
    driver = (ROOT / "tests/experiments/native_chart_mipmap_operations.lua").read_text(encoding="ascii")
    reports = {}
    for operation in ("append", "horizontal", "vertical", "scroll", "continuous"):
        target = output / operation
        target.mkdir()
        continuous = operation == "continuous"
        source = None if continuous else driver.replace(
            'local operation = "append"', f'local operation = "{operation}"'
        )
        native(
            target, 800, True, 73, 20, 3, True, False,
            integrated=continuous, matched=None if continuous else "integrated",
            runtime_source=True, controlled_driver=source,
        )
        report = json.loads((target / "native-results.json").read_text())
        report["kind"] = (
            "actual opt-in chart native continuous callback smoke" if continuous
            else f"actual opt-in chart native {operation}: full-panel input-derived reference comparison"
        )
        report.pop("allowance", None)
        report["quota_policy"] = "Unmodified repository chart runtime; no allowance injection."
        report["runtime_source_unmodified"] = (
            (target / "sdcard/WIDGETS/AeroGrid/panels/chart.lua").read_bytes()
            == (ROOT / "src/WIDGETS/AeroGrid/panels/chart.lua").read_bytes()
        )
        passed = report_passes(report, painted=not continuous) and report["runtime_source_unmodified"]
        reports[operation] = {
            "passed": passed,
            "instruction_upper_bound": report["instruction_upper_bound"],
            "paint": report.get("paint"),
            "measurements": report["measurements"],
        }
        report["runtime_callback_gate_passed"] = passed
        report["limitations"] = [
            "Actual chart source is copied unchanged; internal opt-in dependencies and diagnostic clocks are injected.",
            "Controlled cases replay dense inputs and fence chart observers; continuous smoke does not fence.",
            "Paint references retain normal overlays, not an independent overlay-algorithm oracle.",
            "This gate covers native callback instructions and controlled pixels, not hardware memory or release acceptance.",
        ]
        (target / "native-results.json").write_text(json.dumps(report, indent=2) + "\n")
    passed = all(report["passed"] for report in reports.values())
    summary = {"passed": passed, "operations": reports}
    (output / "runtime-gate.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary, indent=2))
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())

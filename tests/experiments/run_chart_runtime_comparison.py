# SPDX-License-Identifier: GPL-2.0-only
"""Replay one frozen chart workload against two source revisions."""

import argparse
import hashlib
import json
import math
from pathlib import Path
import shutil
import statistics
import subprocess

import run_chart_feasibility as runner
from run_chart_runtime_gate import INPUT_FIELDS, controlled_source, input_signature


def compare(reports):
    if len(reports) < 2:
        raise ValueError("A comparison needs at least two reports")
    signatures = [input_signature(report) for report in reports]
    if any(signature != signatures[0] for signature in signatures[1:]):
        raise ValueError("Input fingerprints differ; latency comparison rejected")
    return signatures[0]


def native_checks_pass(report):
    paint = report.get("paint", {})
    return (
        report.get("callback_trace_complete") is True
        and bool(report.get("callback_samples"))
        and all((value + 1) * 200 < 16000 for value in report["callback_samples"])
        and paint.get("verified") is True
        and paint.get("mismatched_pixels") == 0
        and isinstance(paint.get("paint_complete_ms"), (int, float))
        and not isinstance(paint["paint_complete_ms"], bool)
        and math.isfinite(paint["paint_complete_ms"])
        and paint["paint_complete_ms"] >= 0
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", required=True, help="Base source revision; the current harness is used for both")
    parser.add_argument("--head", default="HEAD")
    parser.add_argument("--case", choices=("append", "horizontal", "vertical", "scroll"), default="horizontal")
    parser.add_argument("--repeat", type=int, default=2)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    root = runner.ROOT
    output = args.output.resolve()
    if not output.is_relative_to(root / "build") or output.exists() or args.repeat < 1:
        parser.error("Choose a fresh output directory under build and a positive repeat count")
    output.mkdir(parents=True)
    harness = output / "harness"
    harness.mkdir()
    harness_hash = hashlib.sha256()
    for directory in ("tests", "tools"):
        shutil.copytree(root / directory, harness / directory, ignore=shutil.ignore_patterns("__pycache__"))
        for path in sorted((harness / directory).rglob("*")):
            if path.is_file():
                harness_hash.update(str(path.relative_to(harness)).encode("utf-8") + b"\0")
                harness_hash.update(path.read_bytes())
    driver = controlled_source(
        (harness / "tests/experiments/native_chart_mipmap_operations.lua").read_text(encoding="ascii"), args.case, {},
    )
    reports, runs = [], []
    for label, ref in (("base", args.base), ("head", args.head)):
        sha = subprocess.check_output(["git", "rev-parse", "--verify", f"{ref}^{{commit}}"], cwd=root, text=True).strip()
        snapshot = output / label
        snapshot.mkdir()
        for directory in ("tests", "tools"):
            shutil.copytree(harness / directory, snapshot / directory)
        archive = snapshot / "source.tar"
        subprocess.run(["git", "archive", f"--output={archive}", sha, "src"], cwd=root, check=True)
        subprocess.run(["tar", "-xf", str(archive), "-C", str(snapshot)], check=True)
        archive.unlink()
        runner.ROOT = snapshot
        for repetition in range(args.repeat):
            target = snapshot / "build" / f"native-{repetition + 1}"
            target.mkdir(parents=True)
            runner.native(
                target, 800, True, 73, 20, 3, True, False, matched="integrated",
                runtime_source=True, controlled_driver=driver, instruction_limit=16000,
            )
            report = json.loads((target / "native-results.json").read_text())
            reports.append(report)
            runs.append({
                "revision": sha, "label": label, "repeat": repetition + 1,
                "paint": report.get("paint"), "phase_profile": report.get("phase_profile"),
                "instruction_upper_bound": report.get("instruction_upper_bound"),
                "native_checks_passed": native_checks_pass(report),
            })
    try:
        signature = compare(reports)
    except ValueError as error:
        (output / "comparison.json").write_text(json.dumps({
            "valid_comparison": False, "error": str(error), "runs": runs,
        }, indent=2) + "\n")
        raise
    native_passed = all(run["native_checks_passed"] for run in runs)
    medians = {
        label: statistics.median(run["paint"]["paint_complete_ms"] for run in runs if run["label"] == label)
        for label in ("base", "head")
    } if native_passed else None
    summary = {
        "valid_comparison": True,
        "input_signature": signature,
        "driver_sha256": hashlib.sha256(driver.encode("ascii")).hexdigest(),
        "harness_sha256": harness_hash.hexdigest(),
        "native_checks_passed": native_passed,
        "median_paint_ms": medians,
        "head_minus_base_ms": medians["head"] - medians["base"] if medians else None,
        "latency_non_regression": native_passed and medians["head"] <= medians["base"],
        "runs": runs,
        "limitations": [
            "Frozen v2 chart arrivals are retained in per-source queues and delivered by scheduled telemetry.",
            "Recording timestamps follow actual polling; oracle validation runs after measurement.",
            "Telemetry, Smart and the other 18 history sources remain background load, not matched service-work traces.",
            "Normal overlays are retained by the pixel reference, not independently reimplemented.",
            "Do not compare these timings to older completion-dependent workloads or silently replace their ceilings.",
        ],
    }
    (output / "comparison.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary, indent=2))
    return 0 if summary["native_checks_passed"] and summary["latency_non_regression"] else 1


if __name__ == "__main__":
    raise SystemExit(main())

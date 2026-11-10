# SPDX-License-Identifier: GPL-2.0-only
"""Attribute native Lua instructions to tasks in the frozen chart benchmark."""

import argparse
from collections import defaultdict
import hashlib
import json
from pathlib import Path

from run_chart_feasibility import ROOT, native
from run_chart_runtime_comparison import compare
from run_chart_runtime_gate import controlled_source, input_signature


def summarize(text):
    callbacks, tasks, recipients = {}, [], set()
    for line in text.splitlines():
        kind, *tokens = line.split()
        fields = dict(token.split("=", 1) for token in tokens)
        if kind == "RECIPIENT":
            if fields["id"] in recipients:
                raise ValueError("Duplicate instruction recipient")
            recipients.add(fields["id"])
        elif kind == "CALLBACK":
            row = {key: value if key == "stage" else int(value) for key, value in fields.items()}
            if row["index"] in callbacks:
                raise ValueError("Duplicate instruction callback")
            if row["period"] != 200 or row["counter"] // 200 != row["firmware_percent"]:
                raise ValueError("Native counter differs from firmware hook")
            callbacks[row["index"]] = row
        elif kind == "TASK":
            tasks.append({key: value if key == "id" else int(value) for key, value in fields.items()})
        else:
            raise ValueError("Unknown instruction profile record")
    if not callbacks or not recipients or sorted(callbacks) != list(range(1, len(callbacks) + 1)):
        raise ValueError("Incomplete instruction profile")
    by_callback, by_recipient = defaultdict(list), defaultdict(list)
    for task in tasks:
        if task["id"] not in recipients or task["callback"] not in callbacks:
            raise ValueError("Unknown task recipient or callback")
        if task["instructions"] < 0 or not 0 <= task["slots"] <= 8:
            raise ValueError("Invalid task accounting")
        by_callback[task["callback"]].append(task)
        by_recipient[task["id"]].append(task)
    residual = 0
    for index, row in callbacks.items():
        assigned = by_callback[index]
        if sum(task["slots"] for task in assigned) + row["unused"] != 8:
            raise ValueError("Slot totals do not balance")
        remaining = row["instructions"] - sum(task["instructions"] for task in assigned)
        if remaining < 0 or row["unused"] < 0 or row["probe"] < 0:
            raise ValueError("Invalid callback accounting")
        residual += remaining
    result = {}
    for recipient in sorted(recipients):
        charges = by_recipient[recipient]
        instructions = [task["instructions"] for task in charges]
        result[recipient] = {
            "calls": len(charges),
            "slots": sum(task["slots"] for task in charges),
            "instructions": sum(instructions),
            "average": sum(instructions) / len(instructions) if instructions else None,
            "minimum": min(instructions, default=None),
            "maximum": max(instructions, default=None),
        }
    return {
        "callbacks": len(callbacks),
        "recipients": result,
        "unused_slots": sum(row["unused"] for row in callbacks.values()),
        "callback_instructions": sum(row["instructions"] for row in callbacks.values()),
        "unattributed_instructions": residual,
        "counter_probe_min": min(row["probe"] for row in callbacks.values()),
        "counter_probe_max": max(row["probe"] for row in callbacks.values()),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--case", choices=("append", "horizontal", "vertical", "scroll"), default="horizontal")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--compare-report", type=Path, help="Require identical inputs to an uninstrumented native report")
    args = parser.parse_args()
    output = args.output.resolve()
    if not output.is_relative_to(ROOT / "build") or output.exists():
        parser.error("Choose a fresh output directory under build")
    output.mkdir(parents=True)
    driver = controlled_source(
        (ROOT / "tests/experiments/native_chart_mipmap_operations.lua").read_text(encoding="ascii"), args.case, {},
    ).replace("local instructionProfiling = false", "local instructionProfiling = true")
    native(
        output, 800, True, 73, 20, 3, True, False, matched="integrated",
        runtime_source=True, controlled_driver=driver, instruction_limit=16000, instruction_profile=True,
    )
    report = json.loads((output / "native-results.json").read_text())
    signature = input_signature(report)
    if args.compare_report:
        signature = compare([json.loads(args.compare_report.read_text()), report])
    summary = summarize((output / "sdcard/instruction-profile.txt").read_text(encoding="ascii"))
    if summary["callbacks"] != int(report["measurements"][0]["callbacks"]):
        raise ValueError("Missing callback instruction records")
    if report.get("paint", {}).get("verified") is not True:
        raise ValueError("Instrumented native output failed its pixel oracle")
    modules = (
        "panels/chart.lua", "lib/chart_mipmap.lua", "lib/chart_mipmap_renderer.lua",
        "lib/history_service.lua", "lib/telemetry_service.lua", "lib/services.lua",
    )
    for path in modules:
        if (output / "sdcard/WIDGETS/AeroGrid" / path).read_bytes() != (ROOT / "src/WIDGETS/AeroGrid" / path).read_bytes():
            raise ValueError(f"Instrumented fixture changed a production module: {path}")
    summary["runtime_sources_sha256"] = {
        path: hashlib.sha256((output / "sdcard/WIDGETS/AeroGrid" / path).read_bytes()).hexdigest()
        for path in modules
    }
    summary["input_signature"] = signature
    summary["limitations"] = [
        "Counts are native Lua VM opcodes, not C++ work or elapsed CPU time.",
        "Task bodies include synchronous observers; private Smart services are included only in flight_poll.",
        "Task counts include the small Lua measurement-boundary overhead; the empty counter probe is reported.",
        "Unattributed work includes scheduling, dispatch, stage profiling and instruction-profile bookkeeping.",
        "The original firmware hook is forwarded every 200 opcodes; each callback verifies the counter.",
        "Activation resets the hook phase by less than 200 opcodes, without resetting its budget percentage.",
        "Instrumented timing and callback totals are diagnostic, not replacement latency/budget acceptance evidence.",
        "Frozen chart-source polls skip their normal recording work; measure live telemetry separately before calibration.",
    ]
    (output / "instruction-summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

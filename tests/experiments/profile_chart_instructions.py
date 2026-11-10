# SPDX-License-Identifier: GPL-2.0-only
"""Attribute native Lua instructions to tasks in the frozen chart benchmark."""

import argparse
from collections import defaultdict
import hashlib
import json
import math
import os
import statistics
from pathlib import Path

from run_chart_feasibility import ROOT, native
from run_chart_runtime_comparison import compare
from run_chart_runtime_gate import controlled_source, input_signature


def distribution(values):
    return {
        "calls": len(values), "minimum": min(values), "median": statistics.median(values),
        "average": statistics.mean(values), "maximum": max(values),
        "population_stddev": statistics.pstdev(values),
    }


def summarize_functions(text, startup_callbacks, chart_source):
    lines = chart_source.splitlines()
    groups = defaultdict(list)
    seen = set()
    for record in text.splitlines():
        kind, *tokens = record.split()
        fields = dict(token.split("=", 1) for token in tokens)
        if kind not in ("FUNCTION", "INCLUSIVE"):
            raise ValueError("Invalid function record")
        callback, line, instructions = (int(fields[key]) for key in ("callback", "line", "instructions"))
        key = (kind, callback, fields["source"], line)
        if key in seen or callback < 1 or line < 0 or instructions < 0:
            raise ValueError("Invalid function accounting")
        seen.add(key)
        if kind != "INCLUSIVE":
            continue
        if fields["source"] != "panels/chart.lua" or not 1 <= line <= len(lines):
            raise ValueError("Unknown chart function")
        phase = "startup" if callback <= startup_callbacks else "operation"
        groups[f"{phase}/{lines[line - 1].strip()}"].append(instructions)
    if not groups:
        raise ValueError("Missing inclusive chart spans")
    return {key: distribution(values) for key, values in sorted(groups.items())}


def summarize_operations(text):
    result = {}
    for line in text.splitlines():
        kind, *tokens = line.split()
        fields = dict(token.split("=", 1) for token in tokens)
        name = fields.pop("kind")
        if kind != "OPERATION" or name in result:
            raise ValueError("Invalid operation profile record")
        row = {key: int(value) for key, value in fields.items()}
        count, total = row["calls"], row["instructions"]
        if min(row.values()) < 0 or count == 0 and any(row.values()):
            raise ValueError("Invalid operation counts")
        if count and not row["minimum"] * count <= total <= row["maximum"] * count:
            raise ValueError("Invalid operation distribution")
        average = total / count if count else None
        row["average"] = average
        row["population_stddev"] = math.sqrt(max(0, row["squares"] / count - average ** 2)) if count else None
        result[name] = row
    if set(result) != {"empty", "update", "position", "reveal", "hide", "activation_probe"}:
        raise ValueError("Incomplete operation profile")
    return result


def summarize(text):
    callbacks, tasks, recipients, charts = {}, [], set(), []
    for line in text.splitlines():
        kind, *tokens = line.split()
        fields = dict(token.split("=", 1) for token in tokens)
        if kind == "RECIPIENT":
            if fields["id"] in recipients:
                raise ValueError("Duplicate instruction recipient")
            recipients.add(fields["id"])
        elif kind == "CALLBACK":
            row = {key: value if key in ("stage", "phase") else int(value) for key, value in fields.items()}
            if row["index"] in callbacks:
                raise ValueError("Duplicate instruction callback")
            if row["period"] != 200 or row["counter"] // 200 != row["firmware_percent"]:
                raise ValueError("Native counter differs from firmware hook")
            callbacks[row["index"]] = row
        elif kind == "TASK":
            tasks.append({key: value if key == "id" else int(value) for key, value in fields.items()})
        elif kind == "CHART":
            charts.append({key: value if key in ("id", "stage", "after") else int(value)
                           for key, value in fields.items()})
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
    per_slot, by_stage = {}, defaultdict(list)
    for recipient in sorted(recipients):
        charges = [task for task in by_recipient[recipient] if task["slots"] > 0]
        if charges:
            row = distribution([task["instructions"] / task["slots"] for task in charges])
            row["charged_slots"] = sum(task["slots"] for task in charges)
            row["slot_weighted_average"] = sum(task["instructions"] for task in charges) / row["charged_slots"]
            per_slot[recipient] = row
    groups, spans = defaultdict(list), defaultdict(list)
    for chart in charts:
        if not any(all(task[key] == chart[key] for key in ("callback", "id", "instructions", "slots"))
                   for task in tasks):
            raise ValueError("Chart detail has no matching task")
        if not 1 <= chart["grant"] <= 8 or chart["series"] < 0:
            raise ValueError("Invalid chart grant or series")
        nested = [chart[key] for key in ("projection", "preparation", "rebuild", "view")]
        if min(nested) < 0 or sum(nested) > chart["instructions"]:
            raise ValueError("Invalid chart subspan accounting")
        key = f'{chart["stage"]}->{chart["after"]}/grant={chart["grant"]}/series={chart["series"]}'
        groups[key].append(chart["instructions"])
        if chart["slots"] > 0:
            by_stage[f'{chart["stage"]}->{chart["after"]}/series={chart["series"]}'].append(
                chart["instructions"] / chart["slots"]
            )
        for category in ("projection", "preparation", "rebuild", "view"):
            if chart[category]:
                spans[f'{category}/grant={chart["grant"]}/series={chart["series"]}'].append(chart[category])
                if category == "projection" and chart.get("columns", -1) >= 0:
                    spans[f'projection/grant={chart["grant"]}/series={chart["series"]}/columns={chart["columns"]}'].append(chart[category])

    return {
        "callbacks": len(callbacks),
        "recipients": result,
        "unused_slots": sum(row["unused"] for row in callbacks.values()),
        "callback_instructions": sum(row["instructions"] for row in callbacks.values()),
        "unattributed_instructions": residual,
        "counter_probe_min": min(row["probe"] for row in callbacks.values()),
        "counter_probe_max": max(row["probe"] for row in callbacks.values()),
        "chart_turns": {key: distribution(values) for key, values in sorted(groups.items())},
        "chart_subspans": {key: distribution(values) for key, values in sorted(spans.items())},
        "instructions_per_charged_slot": per_slot,
        "chart_instructions_per_charged_slot": {
            key: distribution(values) for key, values in sorted(by_stage.items())
        },
        "callback_breakdown": [
            {
                **row,
                "tasks": by_callback[index],
                "residual": row["instructions"] - sum(task["instructions"] for task in by_callback[index]),
            }
            for index, row in sorted(callbacks.items())
        ],
        "chart_fixed_remainder": {
            key: distribution([
                chart["instructions"] - sum(chart[category] for category in
                                            ("projection", "preparation", "rebuild", "view"))
                for chart in charts if f'{chart["stage"]}->{chart["after"]}' == key
            ])
            for key in sorted({f'{chart["stage"]}->{chart["after"]}' for chart in charts})
        },
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--case", choices=("append", "horizontal", "vertical", "scroll"), default="horizontal")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--compare-report", type=Path, help="Require identical inputs to an uninstrumented native report")
    parser.add_argument("--operations", action="store_true", help="Classify native draw-loop opcodes without Lua probes")
    parser.add_argument("--startup", action="store_true", help="Also profile bounded startup and fixed-work function bodies")
    args = parser.parse_args()
    output = args.output.resolve()
    if not output.is_relative_to(ROOT / "build") or output.exists():
        parser.error("Choose a fresh output directory under build")
    output.mkdir(parents=True)
    driver = controlled_source(
        (ROOT / "tests/experiments/native_chart_mipmap_operations.lua").read_text(encoding="ascii"), args.case, {},
    )
    driver = driver.replace("local instructionProfiling = false", "local instructionProfiling = true")
    if args.startup:
        driver = driver.replace("refresh(context)", "profileRefresh(context)")
        marker = "local function tick(context, refresh)"
        if marker not in driver:
            raise ValueError("Missing driver callback marker")
        driver = driver.replace(marker, marker + """
    local function profileRefresh(target)
        local startup = state.phase == "subscriptions" or state.phase == "warming"
            or state.phase == "normal-warm"
        if startup then
            state.startupCallbacks = (state.startupCallbacks or 0) + 1
            assert(state.startupCallbacks <= 1024, "startup exceeded bounded capture")
            Instructions.begin(target, state, Profile.stage, state.phase)
        end
        refresh(target)
        if startup then
            Instructions.finish(target, state)
            Instructions.write(state, "/instruction-profile-startup.txt")
            state.instructionOffset = state.startupCallbacks
            state.instructionRows = {}
        end
    end
""")
        driver = driver.replace(
            'elseif state.phase == "begin" then',
            'elseif state.phase == "begin" then\n        state.instructionRows = {}\n        state.instructionOffset = 0',
        )
        driver = driver.replace(
            'elseif state.phase == "running" then\n        Profile.beginCallback',
            'elseif state.phase == "running" then\n        Instructions.activate()\n        Profile.beginCallback',
        ).replace(
            "Instructions.begin(context, state, Profile.stage)",
            'Instructions.begin(context, state, Profile.stage, "operation", true)',
        )
    if args.operations:
        driver = driver.replace(
            "Instructions.write(state)",
            "if not state.operationsChecked then\n"
            "                Instructions.write(state)\n"
            "                Instructions.checkOperations(context)\n"
            "                state.operationsChecked = true\n"
            "                return\n"
            "            end",
        )
    previous = os.environ.get("AEROGRID_PROFILE_OPERATIONS")
    previous_functions = os.environ.get("AEROGRID_PROFILE_FUNCTIONS")
    try:
        if args.operations:
            os.environ["AEROGRID_PROFILE_OPERATIONS"] = "1"
        if args.startup:
            os.environ["AEROGRID_PROFILE_FUNCTIONS"] = "1"
        native(
            output, 800, True, 73, 20, 3, True, False, matched="integrated",
            runtime_source=True, controlled_driver=driver, instruction_limit=16000, instruction_profile=True,
        )
    finally:
        if previous is None:
            os.environ.pop("AEROGRID_PROFILE_OPERATIONS", None)
        else:
            os.environ["AEROGRID_PROFILE_OPERATIONS"] = previous
        if previous_functions is None:
            os.environ.pop("AEROGRID_PROFILE_FUNCTIONS", None)
        else:
            os.environ["AEROGRID_PROFILE_FUNCTIONS"] = previous_functions
    report = json.loads((output / "native-results.json").read_text())
    if report.get("workload_completed") is not True:
        raise ValueError(f"Native workload did not complete; inspect {output / 'simulator.log'}")
    signature = input_signature(report)
    if args.compare_report:
        signature = compare([json.loads(args.compare_report.read_text()), report])
    summary = summarize((output / "sdcard/instruction-profile.txt").read_text(encoding="ascii"))
    if args.startup:
        summary["startup"] = summarize((output / "sdcard/instruction-profile-startup.txt").read_text(encoding="ascii"))
        summary["function_counts_file"] = "sdcard/instruction-functions.txt"
        summary["chart_function_spans"] = summarize_functions(
            (output / "sdcard/instruction-functions.txt").read_text(encoding="ascii"),
            summary["startup"]["callbacks"],
            (ROOT / "src/WIDGETS/AeroGrid/panels/chart.lua").read_text(encoding="ascii"),
        )
    if args.operations:
        summary["drawing_operations"] = summarize_operations(
            (output / "sdcard/instruction-operations.txt").read_text(encoding="ascii")
        )
        summary["drawing_operation_checks"] = summarize_operations(
            (output / "sdcard/instruction-operations.txt.check").read_text(encoding="ascii")
        )
        if any(row["calls"] != (0 if name == "activation_probe" else 1)
               for name, row in summary["drawing_operation_checks"].items()):
            raise ValueError("Native drawing classifier failed known-path checks")
        projection_total = sum(
            row["average"] * row["calls"] for key, row in summary["chart_subspans"].items()
            if key.startswith("projection/") and "/columns=" not in key
        )
        if sum(row["instructions"] for row in summary["drawing_operations"].values()) > projection_total:
            raise ValueError("Drawing operations exceed their renderer spans")
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
        "Frozen readings are queued at fixed arrival times and recorded by scheduled telemetry at actual poll times.",
        "Chart turns are grouped by entry/exit state, grant and series count, not assumed to be pure stages.",
        "Subspans measure renderer step/prepare and consumer rebuild/view, including small wrapper overhead.",
        "Drawing operation spans cover the column body including ring advance, excluding the for-loop backedge, function setup/teardown and C++ execution.",
        "An activation probe computes geometry but defers a hidden column; it is not a completed column.",
        "Known-path checks exercise each draw branch once after measurement using an offscreen diagnostic object.",
        "Chart fixed remainder is chart time outside measured renderer/consumer subspans, not proven constant overhead.",
        "Function records count self opcodes, excluding callees; callback scope includes profiling and post-refresh driver work.",
        "Inclusive chart spans include callees and report per-callback totals, not per-call distributions; overlapping spans must not be added.",
        "Simulator-generated bytecode can strip chunk names to =?; those self counts remain explicit and are not guessed into chart inclusive spans.",
        "Oracle and hash validation runs after the operation; synchronous recording remains inside scheduled telemetry.",
    ]
    (output / "instruction-summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

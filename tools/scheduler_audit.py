# SPDX-License-Identifier: GPL-2.0-only
"""Scheduler audit helpers: isolated-copy patches, scenarios and result reduction."""
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WIDGET = ROOT / "src/WIDGETS/AeroGrid"
PROBE_DIR = Path(__file__).with_name("scheduler-audit")
SUPPORT_DIR = ROOT / "tests/support"
CASE_DIR = ROOT / "tests/fixtures/scheduler-cases"

MAIN_PREFIX = 'local AUDIT = assert(loadScript("/WIDGETS/AeroGrid/audit/probe.lua"))()\n'
MAIN_PATCHES = (
    ("    create = create,", "    create = function(...)\n        return AUDIT.plain(\"create\", create, ...)\n    end,"),
    ("    update = update,", "    update = function(...)\n        return AUDIT.plain(\"update\", update, ...)\n    end,"),
    ("    refresh = refresh,", "    refresh = function(context, event, touch)\n"
     "        return AUDIT.entry(\"refresh\", context, refresh, event, touch)\n    end,"),
    ("    background = background,", "    background = function(context)\n"
     "        return AUDIT.entry(\"background\", context, background)\n    end,"),
    ("return {\n    name = \"AeroGrid\",", "AUDIT.register(refresh, background)\n\nreturn {\n    name = \"AeroGrid\","),
)
LOADER_PATCHES = (
    ("support.environment()", 'support.environment(assert(loadScript("/WIDGETS/AeroGrid/audit/inputs.lua"))())'),
)
# Call sites inside the chart's staged frame, wrapped so each stage is measured.
CHART_PATCHES = (
    ("chart.render(context)", "AUDIT_SPAN(\"chart.render\", chart.render, context)",
     "    elseif not context.projectionTurn then\n        readingsChanged = chart.render(context)\n"),
    ("    updateHeader(context)\n    if not creating then\n        updateGrid(context, gridQuota)\n",
     "    AUDIT_SPAN(\"chart.header\", updateHeader, context)\n    if not creating then\n"
     "        AUDIT_SPAN(\"chart.grid\", updateGrid, context, gridQuota)\n", None),
    ("        chart.ranges(context)\n        context.rangesReady = true\n",
     "        AUDIT_SPAN(\"chart.ranges\", chart.ranges, context)\n        context.rangesReady = true\n", None),
    ("            prepare(context, item)\n        end\n        if item.job.projecting then\n"
     "            project(context, item, projectionCap)\n            return 5\n        end\n"
     "        if applyRuns(context, item) then\n",
     "            AUDIT_SPAN(\"chart.prepare\", prepare, context, item)\n        end\n"
     "        if item.job.projecting then\n"
     "            AUDIT_SPAN(\"chart.project\", project, context, item, projectionCap)\n            return 5\n        end\n"
     "        if AUDIT_SPAN(\"chart.apply\", applyRuns, context, item) then\n", None),
    ("            prepare(context, item)\n            project(context, item, projectionCap)\n            context.pending = item\n",
     "            AUDIT_SPAN(\"chart.prepare\", prepare, context, item)\n"
     "            AUDIT_SPAN(\"chart.project\", project, context, item, projectionCap)\n            context.pending = item\n",
     None),
    ("        if prepareAxis(context, quota) then\n",
     "        if AUDIT_SPAN(\"chart.axis\", prepareAxis, context, quota) then\n", None),
    ("        if not updateFlights(context) then\n",
     "        if not AUDIT_SPAN(\"chart.flights\", updateFlights, context) then\n", None),
    ("        done = updateSessionMarkers(\n", "        done = AUDIT_SPAN(\n            \"chart.arms\",\n            updateSessionMarkers,\n", None),
    ("            updateSessionMarkers(\n", "            AUDIT_SPAN(\n                \"chart.resumes\",\n                updateSessionMarkers,\n", None),
)


def lua_literal(value):
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return repr(value)
    if isinstance(value, str):
        return json.dumps(value)
    if isinstance(value, (list, tuple)):
        return "{" + ", ".join(lua_literal(item) for item in value) + "}"
    if isinstance(value, dict):
        return "{" + ", ".join(f"[{json.dumps(key)}] = {lua_literal(item)}" for key, item in value.items()) + "}"
    raise TypeError(f"Cannot encode {type(value).__name__}")


def replace_once(source, old, new, name):
    if source.count(old) != 1:
        raise RuntimeError(f"{name}: expected one occurrence of {old.splitlines()[0]!r}, "
                           f"found {source.count(old)}; update the audit instrumentation")
    return source.replace(old, new)


def patch_main(source):
    for old, new in MAIN_PATCHES:
        source = replace_once(source, old, new, "main.lua")
    restart = "        restartLoading(context)\n"
    if source.count(restart) != 2:
        raise RuntimeError("main.lua: expected two foreground/background restart calls")
    source = source.replace(restart, '        AUDIT_SPAN("lifecycle:restartLoading", restartLoading, context)\n')
    return MAIN_PREFIX + source


def patch_mode(source, mode):
    """The host mode of main.lua (`mixed` ships; other modes are audit baselines)."""
    if mode not in ("legacy", "mixed", "new"):
        raise ValueError(f"Unsupported scheduler audit mode: {mode}")
    if mode == "mixed":
        return source
    return replace_once(source, 'local SCHEDULER_MODE = "mixed"', f'local SCHEDULER_MODE = "{mode}"', "main.lua")


def patch_flight_tasks(source):
    """Steady-only adapter eligibility fixture; never changes production owners."""
    start = source.index("pumpFlight = function(context, inputPending)")
    end = source.index("\nlocal function openModelSettings", start)
    pump = source[start:end]
    pump = replace_once(pump, "    local now = getTime()\n",
                        "    local now = getTime()\n"
                        "    if not owner.schedulerEnabled and not context.stage and not context.reloadState then\n"
                        "        owner:enableScheduler(context)\n"
                        "        scheduling.registry = nil\n"
                        "    end\n", "Flight task fixture")
    pump = pump.replace("if owner.smartRuntime then", "if owner.smartRuntime and not owner.schedulerEnabled then")
    pump = replace_once(pump, "    local ok, message = pcall(owner.tick, owner, now, filename)\n",
                        "    local ok, message = true, nil\n"
                        "    if not owner.schedulerEnabled then\n"
                        "        ok, message = pcall(owner.tick, owner, now, filename)\n"
                        "    end\n", "Flight task fixture")
    pump = replace_once(pump, '    if scheduling then\n        scheduling:charge("tick")',
                        '    if scheduling and not owner.schedulerEnabled then\n        scheduling:charge("tick")',
                        "Flight task fixture")
    return source[:start] + pump + source[end:]


def patch_owners(source, owners):
    """Override only named legacy owners in the isolated native image."""
    for task_id in owners:
        if not re.fullmatch(r"(?:panel|service):[\w-]+", task_id):
            raise ValueError(f"Invalid scheduler owner: {task_id}")
        source = replace_once(source, f'["{task_id}"] = "legacy"',
                              f'["{task_id}"] = "new"', "scheduler_host.lua")
    return source


def patch_loader(source):
    for old, new in LOADER_PATCHES:
        source = replace_once(source, old, new, "dashboard_loader.lua")
    return source


def patch_chart(source):
    for old, new, anchor in CHART_PATCHES:
        if anchor:
            source = replace_once(source, anchor, anchor.replace(old, new), "chart.lua")
        else:
            source = replace_once(source, old, new, "chart.lua")
    return source


def supported_spans(panel):
    """Smallest and largest legal span of a panel, as (columns, rows)."""
    text = (WIDGET / "panels" / f"{panel}.lua").read_text()
    match = re.search(r"supportedSpans\s*=\s*\{([^}]*)\}", text)
    names = re.findall(r'"([^"]+)"', match.group(1)) if match else ["any"]
    spans = [(int(a), int(b)) for a, b in (name.split("x") for name in names if name != "any")]
    if not spans:
        spans = [(1, 1), (4, 4)]
    spans.sort(key=lambda span: (span[0] * span[1], span))
    return spans[0], spans[-1]


def reduce_results(results):
    """Flatten native results into per-label rows with per-unit worst cost."""
    rows = {}
    for label, stat in results["stats"].items():
        units = {int(unit): bucket for unit, bucket in stat["units"].items()}
        top = max(units)
        rows[label] = {
            "n": stat["n"], "mean": round(stat["mean"], 1), "min": stat["min"], "max": stat["max"],
            "selfMax": stat["selfMax"], "maxUnits": top, "maxAtMaxUnits": units[top]["max"],
            "perUnit": round(max(bucket["max"] / unit for unit, bucket in units.items()), 1),
        }
    return rows


def verify_hook(exact, firmware, quantum=200, tolerance=1):
    """Compare the exact counter with getUsage read one callback later."""
    problems = []
    for index in range(1, len(exact["counts"])):
        expected = exact["counts"][index - 1] // quantum
        reported = firmware["usages"][index]
        if abs(expected - reported) > tolerance:
            problems.append((index, exact["counts"][index - 1], reported))
    return problems


def aggregate(runs):
    """Worst observed cost per task label across scenarios.

    `runs` maps scenario name to native results. Each row keeps the scenario that
    produced the maximum, the units in that call, and the worst cost per unit.
    """
    rows = {}
    for scenario, results in runs.items():
        for label, row in reduce_results(results).items():
            best = rows.get(label)
            if best is None:
                rows[label] = dict(row, scenario=scenario, total=row["n"], weighted=row["mean"] * row["n"])
                continue
            best["total"] += row["n"]
            best["weighted"] += row["mean"] * row["n"]
            best["perUnit"] = max(best["perUnit"], row["perUnit"])
            if row["max"] > best["max"]:
                best.update(max=row["max"], scenario=scenario, maxUnits=row["maxUnits"],
                            maxAtMaxUnits=row["maxAtMaxUnits"], selfMax=row["selfMax"])
    for row in rows.values():
        row["mean"] = round(row.pop("weighted") / row["total"], 1)
        row["n"] = row.pop("total")
    return rows


def hook_check_status(exact, firmware):
    """Return (ok, message) for a pair of hook-check results."""
    problems = verify_hook(exact, firmware)
    if problems:
        return False, f"hook-check MISMATCH between the exact counter and getUsage: {problems}"
    return True, "hook-check: exact counter agrees with getUsage"


def framework_report(data):
    """Return (ok, lines) for the framework measurements of `--framework`.

    `ok` is false when a callback cost more than the planner charged for it or a
    task step exceeds its declared bound.
    """
    verdict, charges = data["verdict"], data["charges"]
    rows = sorted(data["overhead"]["rows"], key=lambda row: row["slack"])
    lines = [f"framework cost per callback: charged {charges['fixed']} + {charges['examine']} per task examined "
             f"+ {charges['run']} per task run",
             "scenario\ttasks\tmeasured\tcharged\texamined\tran\tslack"]
    for row in rows[:12]:
        lines.append("\t".join(str(row[key]) for key in ("name", "tasks", "measured", "charged", "examined", "ran", "slack")))
    lines.append(f"{len(rows)} scenarios and mixes measured; least slack {verdict['slack']} "
                 f"({verdict['tightest']['name']})")
    lines.append(f"least headroom (charged / measured) {verdict['headroom']:.3f} ({verdict['tightestRatio']['name']})")
    lines.append(f"measured: idle callback {verdict['fixed']}, {verdict['examine']:.1f} per task examined, "
                 f"{verdict['perRun']:.1f} per task run (examination included)")
    lines.append("OK: every measured callback is within its charge" if verdict["ok"] else
                 "FAIL: over the charge: " + ", ".join(row["name"] for row in verdict["failures"]))
    heap = data["overhead"]["heap"]
    lines.append(f"heap: {heap['kib']:.1f} KiB for {heap['tasks']} tasks")
    ok = verdict["ok"]
    for task, report in sorted(data["cases"].items()):
        for stage, grants in sorted(report["worst"].items()):
            if isinstance(grants, list):  # the native encoder writes grants 1..n as an array
                grants = {str(grant): cost for grant, cost in enumerate(grants, 1)}
            lines.append(f"{task}.{stage}: worst per grant " + " ".join(f"{g}={grants[g]}" for g in sorted(grants, key=int))
                         + f"; proposed {report['proposed'][stage]}")
        if "planner" in report:
            planner = report["planner"]
            lines.append(f"{task}: framework cost of one release {planner['measured']}, charged {planner['charged']}")
            ok = ok and planner["measured"] <= planner["charged"]
        for finding in report["findings"]:
            lines.append(f"{task}.{finding['stage']} grant {finding['grant']}: {finding['level']} "
                         f"({finding['ratio']:.0%} of the declared bound)")
            ok = ok and finding["level"] != "exceeds"
    return ok, lines

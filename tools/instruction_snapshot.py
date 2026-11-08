# SPDX-License-Identifier: GPL-2.0-only
"""Read and write src/WIDGETS/AeroGrid/lib/instruction_snapshot.lua.

The snapshot is one Lua chunk returning `function(section)`. The widget asks
only for "estimates"; the "record" section (observations, provenance and
coverage) is built only by the measurement tools.
"""

from pathlib import Path
import hashlib
import importlib.util
import copy
import csv
import json
import os
import subprocess
import tempfile
import signal
import sys
import time

from lupa.lua53 import LuaRuntime, lua_type

ROOT = Path(__file__).resolve().parents[1]
SNAPSHOT = ROOT / "src/WIDGETS/AeroGrid/lib/instruction_snapshot.lua"
SCHEMA = 1
CEILING = 15000
MARGIN = 400
MIN_SAMPLES = 1
PROFILE_SECONDS = 300
# These tasks return without progress unless the whole requested grant fits.
INDIVISIBLE_GRANT_TASKS = {"telemetry.maintenance", "telemetry.recorded"}
MEMORY_SUITES = (
    "tests/integration/widget/test_shared_module_code.lua",
    "tests/integration/widget/test_aircraft_memory.lua",
    "tests/integration/widget/test_output_memory.lua",
)
CANDIDATE_SCENARIOS = ("stress-clock", "aircraft-link-recovery")
NATIVE_SCENARIOS = ("hook-check", "hook-check-firmware") + CANDIDATE_SCENARIOS
MOCK_SUITES = tuple(
    f"tests/unit/lib/test_{name}.lua" for name in (
        "instruction_samples", "scheduler_registration", "scheduler_registration_load",
        "model_settings_open", "model_settings_ui", "editor_drawer",
    )
) + tuple(
    f"tests/integration/widget/test_{name}.lua" for name in (
        "flight_loading", "layout_loading_chunks",
        "dashboard_lifecycle", "dashboard_lifecycle_admission",
        "editor_input_admission", "editor_list_admission", "location_details", "session_reset",
        "instruction_foreground",
    )
)

def profile_spec(spec):
    """Sample steady phases; leave action/deadline assertions and loading intact."""
    result = dict(spec, instructionProfile=True, deterministicClock=True)
    result["phases"] = [
        dict(phase, callbacks=40 if phase["kind"] == "refresh" else 10, perCall=1)
        if phase["name"] in ("refresh", "background") and not phase.get("action") else dict(phase)
        for phase in spec.get("phases", [])
    ]
    return result


def round_estimate(value):
    return ((value + 499) // 500) * 500


def save_report(path, report):
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", encoding="ascii", dir=path.parent,
                                         suffix=".json.tmp", delete=False) as file:
            temporary = Path(file.name)
            json.dump(report, file, indent=2)
            file.write("\n")
        os.replace(temporary, path)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def target(maximum):
    """ceil500(1.1 * maximum), without rounding observations."""
    if type(maximum) is not int or not 0 <= maximum <= CEILING:
        raise ValueError(f"invalid measured maximum: {maximum!r}")
    return ((11 * maximum + 4999) // 5000) * 500


def spread(minimum, maximum):
    return maximum - minimum > 300 and 2 * maximum > 3 * minimum


def fit(grants):
    """Measured incremental growth above grant one, then minimal startup cost."""
    if 1 not in grants:
        raise ValueError("stage fitting requires grant one")
    targets = {grant: target(maximum) for grant, maximum in grants.items()}
    per_unit = 1
    for grant, budget in targets.items():
        if type(grant) is not int or grant < 0:
            raise ValueError(f"invalid fitting grant: {grant!r}")
        if grant > 1:
            growth = budget - targets[1]
            per_unit = max(per_unit, (growth + grant - 2) // (grant - 1))
    if not any(grant > 1 for grant in targets):
        fixed = targets.get(0, 0)
        return {"fixed": fixed, "perUnit": round_estimate(max(1, targets[1] - fixed))}
    per_unit = round_estimate(per_unit)
    fixed = max(0, max(budget - grant * per_unit for grant, budget in targets.items()))
    return {"fixed": round_estimate(fixed), "perUnit": per_unit}


def observation_key(row):
    return "|".join(str(row[field]) for field in ("kind", "name", "stage", "grant"))


def deferred(data, row):
    return (row["kind"] == "task" and row["name"] in data["record"]["deferred"]
            or row["kind"] == "bound" and row["stage"] == "chart"
            and row["name"] in ("panel-reflow", "editor-layout"))


def merge_observations(rows):
    """Keep cheap, no-op and failed executions, without averaging maxima."""
    merged = {}
    for row in rows:
        for field in ("kind", "name", "stage", "minScenario", "maxScenario"):
            if not isinstance(row.get(field), str):
                raise ValueError(f"observation lacks {field}: {row!r}")
        for field in ("grant", "n", "min", "max", "failures"):
            if type(row.get(field)) is not int or row[field] < 0:
                raise ValueError(f"invalid observation {field}: {row!r}")
        if row["n"] == 0 or row["min"] > row["max"] or row["failures"] > row["n"]:
            raise ValueError(f"invalid observation range/count: {row!r}")
        expected = row.get("expectedFailures", 0)
        if type(expected) is not int or not 0 <= expected <= row["failures"]:
            raise ValueError(f"invalid expected failure count: {row!r}")
        key = observation_key(row)
        previous = merged.get(key)
        if previous is None:
            merged[key] = dict(row)
            continue
        previous["n"] += row["n"]
        previous["failures"] += row["failures"]
        previous["expectedFailures"] = previous.get("expectedFailures", 0) + expected
        if row["min"] < previous["min"]:
            previous["min"], previous["minScenario"] = row["min"], row["minScenario"]
        if row["max"] > previous["max"]:
            previous["max"], previous["maxScenario"] = row["max"], row["maxScenario"]
    return merged


def check(snapshot, observations, required, *, updating=False, require_previous=True):
    """Independent regression, runtime, safety, coverage and spread findings.

    `required` is an explicit set of observation keys, including every legal
    grant of every non-deferred task stage and every foreground/framework bound.
    Environment records stay separate; only coverage and targets combine them.
    """
    findings = []
    if set(observations) != {"mock", "native"} or not all(observations.values()):
        findings.append("coverage: fresh mock AND native observations are required")
    previous = snapshot["record"]["observations"]
    combined = {}
    for environment, rows in observations.items():
        if environment not in ("mock", "native"):
            findings.append(f"coverage: unknown environment {environment}")
            continue
        if require_previous:
            for key, row in previous.get(environment, {}).items():
                if not deferred(snapshot, row) and key not in rows:
                    findings.append(f"coverage: missing previously recorded {environment}:{key}")
        for key, row in rows.items():
            if key != observation_key(row):
                raise ValueError(f"observation key mismatch: {key}")
            if row["max"] > CEILING:
                findings.append(f"safety: {environment}:{key} exceeds {CEILING}")
            if row["failures"] > row.get("expectedFailures", 0):
                findings.append(f"behavior: {environment}:{key} has failed executions")
            if deferred(snapshot, row):
                continue
            old = previous.get(environment, {}).get(key)
            if not updating:
                if old is None:
                    findings.append(f"regression: missing recorded maximum for {environment}:{key}")
                elif row["max"] > old["max"]:
                    findings.append(f"regression: {environment}:{key} grew from {old['max']} to {row['max']}")
            estimates = snapshot["estimates"]
            if row["kind"] == "task":
                stage = estimates["tasks"].get(row["name"], {}).get(row["stage"])
                if stage is None:
                    findings.append(f"runtime: missing task estimate for {key}")
                else:
                    charge = stage["fixed"] + stage["perUnit"] * row["grant"]
                    if row["max"] > charge:
                        findings.append(f"runtime: {environment}:{key} exceeds its declared bound")
                    if stage["fixed"] + stage["perUnit"] > CEILING - MARGIN:
                        findings.append(f"safety: {key} cannot fit beneath the ceiling and margin")
                    if row["name"] in INDIVISIBLE_GRANT_TASKS and charge > CEILING - MARGIN:
                        findings.append(f"progress: {environment}:{key} requires {charge} instructions; "
                                        f"indivisible grant cannot fit within {CEILING - MARGIN}")
            elif row["kind"] == "bound":
                bound = estimates["bounds"].get(row["name"], {}).get(row["stage"])
                if bound is None:
                    findings.append(f"runtime: missing foreground/framework estimate for {key}")
                elif row["max"] > bound:
                    findings.append(f"runtime: {environment}:{key} exceeds its declared bound")
            elif row["kind"] == "framework" and row["name"] == "scheduler":
                examined, ran = map(int, row["stage"].split(":"))
                bounds = estimates["bounds"]["scheduler"]
                charge = bounds["fixed"] + examined * bounds["examine"] + ran * bounds["run"]
                if row["max"] > charge:
                    findings.append(f"runtime: {environment}:{key} exceeds its joint framework charge {charge}")
            elif row["kind"] != "callback":
                findings.append(f"coverage: unknown observation kind for {key}")
            combined.setdefault(key, []).append(row)
    for key in sorted(required):
        rows = combined.get(key, [])
        if not rows:
            findings.append(f"coverage: missing {key}")
        elif rows[0]["kind"] == "task" and sum(row["n"] for row in rows) < MIN_SAMPLES:
            findings.append(f"coverage: {key} needs {MIN_SAMPLES} combined samples")
    for key, rows in combined.items():
        minimum, maximum = min(row["min"] for row in rows), max(row["max"] for row in rows)
        if rows[0]["kind"] == "task" and spread(minimum, maximum):
            findings.append(f"efficiency: {key} spreads from {minimum} to {maximum}")
    return findings


def _python(value):
    if lua_type(value) == "table":
        return {key: _python(item) for key, item in value.items()}
    return value


def load(path=SNAPSHOT):
    """Both sections of a snapshot as plain Python data."""
    lua = LuaRuntime(unpack_returned_tuples=True)
    chunk = lua.eval("loadfile")(str(path))
    if chunk is None:
        raise ValueError(f"cannot load {path}")
    snapshot = chunk()
    return {"estimates": _python(snapshot("estimates")), "record": _python(snapshot("record"))}


def _key(key):
    if isinstance(key, int):
        return f"[{key}]"
    return f"[{_value(key, 0)}]"


def _value(value, indent):
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int):
        if not 0 <= value <= 2147483647:
            raise ValueError(f"snapshot integer is outside radio range: {value}")
        return str(value)
    if isinstance(value, str):
        value.encode("ascii")
        return json.dumps(value)
    if isinstance(value, dict):
        if not value:
            return "{}"
        pad = "    " * (indent + 1)
        lines = [f"{pad}{_key(key)} = {_value(value[key], indent + 1)}," for key in sorted(value, key=_order)]
        return "{\n" + "\n".join(lines) + "\n" + "    " * indent + "}"
    raise TypeError(f"snapshot values must be integers, strings, booleans or tables: {value!r}")


def _order(key):
    return (0, key, "") if isinstance(key, int) else (1, 0, key)


def render(estimates, record):
    """The snapshot file text, with deterministic ordering."""
    for task, stages in estimates["tasks"].items():
        for stage, estimate in stages.items():
            if set(estimate) != {"fixed", "perUnit"}:
                raise ValueError(f"{task}.{stage}: estimates need exactly fixed and perUnit")
            if (type(estimate["fixed"]) is not int or estimate["fixed"] < 0
                    or type(estimate["perUnit"]) is not int or estimate["perUnit"] <= 0):
                raise ValueError(f"{task}.{stage}: invalid scheduler coefficients")
    return (
        "-- SPDX-License-Identifier: GPL-2.0-only\n\n"
        "-- GENERATED by tools/instruction_snapshot.py. Do not edit by hand.\n"
        "-- Instruction estimates read by lib/costs.lua; \"record\" holds the\n"
        "-- observations they were derived from.\n\n"
        "return function(section)\n"
        '    if section == "estimates" then\n'
        f"        return {_value(estimates, 2)}\n"
        "    end\n"
        f"    return {_value(record, 1)}\n"
        "end\n"
    )


def write(estimates, record, path=SNAPSHOT, *, expected_sha, deadline=None):
    """Replace atomically without overwriting a known concurrent edit."""
    text = render(estimates, record)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", encoding="ascii", dir=path.parent,
                                         prefix=path.name + ".", suffix=".tmp", delete=False) as file:
            temporary = Path(file.name)
            file.write(text)
            file.flush()
            os.fsync(file.fileno())
        if hashlib.sha256(path.read_bytes()).hexdigest() != expected_sha:
            raise RuntimeError("instruction snapshot changed during measurement; refusing replacement")
        if deadline is not None and time.monotonic() >= deadline:
            raise RuntimeError("time: five-minute deadline expired; refusing replacement")
        temporary.replace(path)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


DEFERRED_SUITES = {
    f"tests/integration/widget/{name}.lua" for name in (
        "test_chart_recording", "test_chart_independent_arming",
        "test_chart_flight_recording", "test_smart_chart_budget",
    )
}


def _module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def required_keys(data, declarations):
    required, errors = set(), []
    deferred_tasks = data["record"]["deferred"]
    for task, stages in data["estimates"]["tasks"].items():
        if task in deferred_tasks:
            continue
        for stage in stages:
            maximum = declarations.get(f"{task}|{stage}")
            if maximum is None:
                errors.append(f"coverage: no declaration measured for {task}.{stage}")
                continue
            required.update(f"task|{task}|{stage}|{grant}" for grant in range(1, maximum + 1))
    for group, bounds in data["estimates"]["bounds"].items():
        if group == "scheduler":
            continue
        for name in bounds:
            if name == "chart" and group in ("panel-reflow", "editor-layout"):
                continue
            required.add(f"bound|{group}|{name}|0")
    for rows in data["record"]["observations"].values():
        required.update(key for key, row in rows.items() if not deferred(data, row))
    if "scheduler" in data["estimates"]["bounds"]:
        required.add("framework|scheduler|0:0|0")
    return required, errors


def propose(data, observations, declarations, required):
    """No absent observation may change an estimate or disappear from the record."""
    combined = {}
    for rows in observations.values():
        for row in rows.values():
            key = observation_key(row)
            combined[key] = max(combined.get(key, 0), row["max"])
    missing = required - combined.keys()
    if missing:
        raise ValueError(f"cannot fit incomplete observations: {sorted(missing)}")
    estimates = copy.deepcopy(data["estimates"])
    framework = estimates["bounds"].get("scheduler")
    if framework is not None:
        framework["fixed"] = round_estimate(framework["fixed"])
        for rows in observations.values():
            for row in rows.values():
                if row["kind"] == "framework" and row["name"] == "scheduler":
                    examined, ran = map(int, row["stage"].split(":"))
                    variable = examined * framework["examine"] + ran * framework["run"]
                    if row["max"] > framework["fixed"] + variable:
                        framework["fixed"] = max(framework["fixed"], target(row["max"] - variable))
    for task, stages in estimates["tasks"].items():
        if task in data["record"]["deferred"]:
            continue
        for stage in stages:
            maximum = declarations.get(f"{task}|{stage}")
            if maximum is None:
                raise ValueError(f"cannot fit an undeclared stage: {task}.{stage}")
            grants = {grant: combined[f"task|{task}|{stage}|{grant}"]
                      for grant in range(1, maximum + 1)}
            noop = combined.get(f"task|{task}|{stage}|0")
            if noop is not None:
                grants[0] = noop
            stages[stage] = fit(grants)
    for group, bounds in estimates["bounds"].items():
        if group == "scheduler":
            continue
        for name in bounds:
            if name == "chart" and group in ("panel-reflow", "editor-layout"):
                continue
            bounds[name] = target(combined[f"bound|{group}|{name}|0"])
    return estimates


def native_bound(label, estimates):
    """Map actual audited operations, not their reservation getters, to bounds."""
    prefixes = (
        ("host:overhead:", "host-overhead"),
        ("registration:advance:", "flight-registration"),
        ("modal:settings:load:", "settings-store-load"),
        ("modal:settings:store:", "settings-store-save"),
        ("editor:drawer:advance:", "editor-drawer"),
        ("editor:advanceEditor:drag:", "editor-drag"),
        ("editor:advanceEditor:drawer-open:", "editor-drawer-open"),
        ("editor:advanceEditor:layout:", "editor-layout"),
        ("editor:input:bound:", "editor-input"),
        ("modal:log:advance:", "log-viewer"),
    )
    for prefix, group in prefixes:
        if label.startswith(prefix):
            stage = label[len(prefix):].split(":")[0]
            if stage in estimates["bounds"][group]:
                return group, stage, False
            return None
    readiness = "scheduler:ready:"
    if label.startswith(readiness):
        stage = label[len(readiness):]
        if stage == "settled":
            return None
        if stage == "panel-enroll":
            return "host", "panelEnroll", False
        if stage == "service-enroll":
            return "host", "serviceEnroll", False
        return "host", "reconcile", False
    if label == "registration:begin":
        return "flight-registration", "begin", False
    if label.startswith("main:flightJob:"):
        stage = label[len("main:flightJob:"):]
        if stage in ("error", "registration"):
            return "main", "flightError" if stage == "error" else "registrationOverhead", True
        return None
    if label == "registration:beginLoad":
        return "flight-registration", "load-begin", False
    if label.startswith("editor:advanceEditor:render:"):
        stage = int(label.split(":")[-1])
        if 2 <= stage <= 6:
            return "editor-render", "finish" if stage == 6 else "rows", False
    if label.startswith("editor:advanceEditor:build:"):
        return "main", "editorBuild", False
    if label.startswith("modal:location:handle:"):
        return "main", "modalLocation", False
    if label == "main:modalMenu":
        return "main", "modalMenu", False
    if label in ("host:head:reset", "host:head:handoff"):
        return "host", label.split(":")[-1], False
    if label.startswith("load:flight-load-wait:shared:"):
        return "dashboard-loader", "sharedFlightOverhead", True
    if label == "lifecycle:beginReflow":
        return "dashboard-lifecycle", "reflowBegin", False
    if label == "lifecycle:waitReflow":
        return "dashboard-lifecycle", "reflowWait", True
    if label == "lifecycle:rebuildPage":
        return "dashboard-lifecycle", "rebuild", False
    if label == "lifecycle:restartLoading":
        return "main", "restartLoad", False
    if label.startswith("lifecycle:advanceReflow:"):
        stage = label[len("lifecycle:advanceReflow:"):]
        if stage in ("finish", "skip"):
            return "dashboard-lifecycle", "reflowFinish" if stage == "finish" else "reflowSkip", False
        panel = stage.split(":")[0]
        if panel != "chart" and panel in estimates["bounds"]["panel-reflow"]:
            return "panel-reflow", panel, False
    if label.startswith(("lifecycle:retirePage:", "lifecycle:advanceAppRebuild:")):
        stage = label.split(":")[2]
        if stage == "settings":
            return ("dashboard-lifecycle", "settingsDrain", False) if label.count(":") > 2 else (
                "dashboard-lifecycle", "settingsAbsent", False)
        if stage in estimates["bounds"]["dashboard-lifecycle"]:
            return "dashboard-lifecycle", stage, False
    if label.startswith("load:theme-publish:"):
        return "dashboard-loader", "theme-publish", False
    if label.startswith("modal:settings:advance:"):
        stage = label.split(":")[3]
        if stage.startswith("save_"):
            return "settings-ui", "storeOverhead", True
        if stage.startswith("load_"):
            stage = stage[len("load_"):]
            if stage in ("read", "parse", "build", "previous"):
                return "settings-ui", "storeOverhead", True
            group = "settings-ui-load"
        else:
            group = "settings-ui"
        if stage.startswith("publish_"):
            stage = "publish"
        if stage in estimates["bounds"][group]:
            return group, stage, False
    if label.startswith("modal:menu:close:"):
        return "menu", "close", False
    if label.startswith("modal:menu:advance:"):
        stage = label.split(":")[3]
        if stage in ("pending", "idle"):
            return "menu", stage, False
    return None


def native_rows(scenario, results, estimates=None):
    """Use actual granted units, not the number of entries that happened to work."""
    service_names = {
        "model": "model", "armed": "armed", "navigation": "navigation", "history": "history",
        "control": "control.critical", "control-normal": "control.normal",
        "control-outputs": "control.outputs", "flight": "flight", "smart": "flight.smart",
        "telemetry:maintenance": "telemetry.maintenance",
    }
    estimates = estimates or load()["estimates"]
    rows = []
    for label, stat in results["stats"].items():
        kind = name = stage = None
        exclusive = False
        if label.startswith("task:panel:"):
            panel, stage = label[len("task:panel:"):].rsplit(":", 1)
            kind, name = "task", "panel." + panel
        elif label.startswith("task:service:"):
            task, stage = label[len("task:service:"):].rsplit(":", 1)
            if task.startswith("telemetry:source:"):
                name = "telemetry." + task.split(":")[2]
            else:
                name = service_names.get(task)
            if name is None:
                raise ValueError(f"unmapped native scheduler task: {label}")
            kind = "task"
        elif label.startswith("callback:"):
            kind, name = "callback", label.split(":")[1]
            loading = name.endswith("@load")
            if loading:
                name = name[:-5]
            if name not in ("create", "update", "refresh", "background"):
                continue
            stage = scenario + ":" + ("load:" if loading else "") + ":".join(label.split(":")[2:])
        elif label.startswith("scheduler:framework:"):
            kind, name, stage, exclusive = "framework", "scheduler", label[len("scheduler:framework:"):], True
        elif label.startswith("load:theme-resolve:"):
            kind, name, stage = "bound", "theme-resolution", label.split(":")[-1]
        elif label.startswith("load:") and label.count(":") == 1:
            candidate = label.split(":")[1]
            if candidate in estimates["bounds"]["dashboard-loader"]:
                kind, name, stage = "bound", "dashboard-loader", candidate
        if kind is None:
            bound = native_bound(label, estimates)
            if bound is not None:
                name, stage, exclusive = bound
                kind = "bound"
        if kind is None:
            continue
        for grant, bucket in stat["units"].items():
            minimum, maximum = ("selfMin", "selfMax") if exclusive else ("min", "max")
            if minimum not in bucket:
                raise ValueError(f"native observations need per-grant minima: {scenario}:{label}")
            rows.append(dict(kind=kind, name=name, stage=stage, grant=int(grant) if kind == "task" else 0,
                             n=bucket["n"], min=bucket[minimum], max=bucket[maximum], failures=0,
                             minScenario=scenario, maxScenario=scenario))
            if kind == "bound" and name == "dashboard-lifecycle" and stage == "settingsDrain":
                if "selfMin" not in bucket or "selfMax" not in bucket:
                    raise ValueError(f"native settings drain needs exclusive ranges: {scenario}:{label}")
                rows.append(dict(kind="bound", name=name, stage="settingsDrainOverhead", grant=0,
                                 n=bucket["n"], min=bucket["selfMin"], max=bucket["selfMax"], failures=0,
                                 minScenario=scenario, maxScenario=scenario))
    return rows


def task_rows(data, measurement):
    """Observed ranges beside the current shipped bound, including missing grants."""
    keys = set()
    by_environment = {}
    for environment in ("mock", "native"):
        rows = measurement["observations"][environment]
        by_environment[environment] = rows
        keys.update(key for key, row in rows.items() if row["kind"] == "task")
    keys.update(key for key in measurement.get("requiredObservations", []) if key.startswith("task|"))
    # Earlier profile reports kept coverage keys only in their diagnostics.
    prefix = "coverage: missing task|"
    keys.update("task|" + error[len(prefix):] for error in measurement["errors"] if error.startswith(prefix))
    result = []
    for key in keys:
        _, task, stage, grant = key.split("|")
        grant = int(grant)
        environments = {environment: rows.get(key) for environment, rows in by_environment.items()}
        observed = [row for row in environments.values() if row is not None]
        estimate = data["estimates"]["tasks"].get(task, {}).get(stage)
        current = None if estimate is None else estimate["fixed"] + grant * estimate["perUnit"]
        minimum = min((row["min"] for row in observed), default=None)
        maximum = max((row["max"] for row in observed), default=None)
        samples = sum(row["n"] for row in observed)
        flags = []
        if estimate is None:
            flags.append("MISSING ESTIMATE")
        if not observed:
            flags.append("UNMEASURED")
        elif task not in data["record"]["deferred"]:
            if samples < MIN_SAMPLES:
                flags.append(f"SAMPLES < {MIN_SAMPLES}")
            if current is not None and maximum > current:
                flags.append("OVER BOUND")
            if spread(minimum, maximum):
                flags.append("SPREAD")
        if task in data["record"]["deferred"]:
            flags.append("DEFERRED")
        row = dict(task=task, stage=stage, grant=grant, min=minimum, curr=current,
                   max=maximum, samples=samples, status=", ".join(flags) or "within bound")
        for environment, observation in environments.items():
            for field in ("min", "max", "n"):
                row[environment + "_" + field] = None if observation is None else observation[field]
        result.append(row)
    return sorted(result, key=lambda row: (row["task"], row["stage"], row["grant"]))


def task_report(path, output=None):
    """Generate an inspectable Markdown table and CSV without remeasuring."""
    measurement = json.loads(path.read_text(encoding="ascii"))
    rows = task_rows(load(), measurement)
    output = output or path.with_name("instruction-tasks.md")
    def cell(value):
        return "N/A" if value is None else str(value)
    def environment(row, name):
        if row[name + "_n"] is None:
            return "not measured"
        return f"{row[name + '_min']}-{row[name + '_max']} ({row[name + '_n']})"
    lines = [
        "# Measured task instructions", "",
        "**min/max:** observed instructions across mock and native. "
        "**curr:** the current shipped bound (`fixed + perUnit * grant`), not the latest sample.",
        "", f"Source: `{path.name}`. Blocking findings: **{len(measurement['errors'])}**; "
        f"review warnings: **{len(measurement.get('warnings', []))}**. "
        "This report is not a validated baseline.",
        "", "| Task | Stage | Grant | min | curr (bound) | max | Mock min-max (n) | Native min-max (n) | Status |",
        "| --- | --- | ---: | ---: | ---: | ---: | --- | --- | --- |",
    ]
    for row in rows:
        values = [row["task"], row["stage"], row["grant"], row["min"], row["curr"], row["max"],
                  environment(row, "mock"), environment(row, "native"), row["status"]]
        lines.append("| " + " | ".join(cell(value) for value in values) + " |")
    output.write_text("\n".join(lines) + "\n", encoding="ascii")
    with output.with_suffix(".csv").open("w", encoding="ascii", newline="") as file:
        writer = csv.DictWriter(file, fieldnames=list(rows[0]) if rows else ["task", "stage", "grant", "min", "curr", "max"])
        writer.writeheader()
        writer.writerows(rows)
    print(f"{len(rows)} task/stage/grant rows: {output}")
    return 0


def validate_candidate(audit, runner, args, estimates, record, executable, library, capture, suites,
                       *, discovery=False):
    """Exercise the exact populated chunk without replacing the shipped snapshot."""
    errors = []
    result = {"mock": [], "chartBehavior": [], "chartFailures": [],
              "instrumentedMock": [], "native": [], "observations": {}, "workSamples": [],
              "nativeMeasurements": {}}
    directory = ROOT / "build/scheduler-audit"
    directory.mkdir(parents=True, exist_ok=True)
    candidate = temporary = None
    try:
        text = render(estimates, record)
        digest = hashlib.sha256(text.encode("ascii")).hexdigest()
        with tempfile.NamedTemporaryFile(mode="w", encoding="ascii", suffix=".lua",
                                         prefix="snapshot-candidate-", dir=directory, delete=False) as file:
            temporary = Path(file.name)
            file.write(text)
        candidate = directory / f"instruction-candidate-{digest}.lua"
        os.replace(temporary, candidate)
        temporary = None
        result["bytes"] = len(text.encode("ascii"))
        result["sha256"] = digest
        result["artifact"] = candidate.relative_to(ROOT).as_posix()
        progress = directory / f"candidate-progress-{digest}.json"
        def checkpoint():
            save_report(progress, {"errors": errors + ["candidate: validation has not completed"], "result": result})
        checkpoint()
        for name in (() if discovery else MEMORY_SUITES):
            try:
                runner.run_test(ROOT / name, snapshot_path=candidate)
                result["mock"].append(name)
            except Exception as error:
                errors.append(f"memory: candidate {name}: {error}")
            checkpoint()
        try:
            if discovery:
                lua32 = None
            else:
                lua32 = subprocess.run(
                    [str(ROOT / "build/lua32/lua"), str(ROOT / "tests/support/lua32.lua"),
                     str(ROOT / MEMORY_SUITES[0]), str(ROOT), str(candidate)],
                    cwd=ROOT, text=True, capture_output=True, timeout=args.timeout, check=True,
                )
            if lua32 is not None:
                result["lua32Memory"] = lua32.stdout.strip()
        except (OSError, subprocess.SubprocessError) as error:
            details = getattr(error, "stderr", None) or getattr(error, "stdout", None)
            errors.append(f"memory: candidate Lua32 shared-module: {error}"
                          + (f"\n{details}" if details else ""))
        for name in (() if discovery else sorted(DEFERRED_SUITES)):
            try:
                runner.run_test(ROOT / name, snapshot_path=candidate)
                result["chartBehavior"].append(name)
            except Exception as error:
                result["chartFailures"].append(f"behavior: candidate {name}: {error}")
            checkpoint()
        if errors:
            save_report(progress, {"errors": errors, "result": result})
            return errors, result
        mock = []
        for path in suites:
            try:
                rows, _ = runner.run_test(path, instructions=True, snapshot_path=candidate,
                                          work_samples=result["workSamples"])
                for value in rows.values():
                    row = _python(value)
                    row["expectedFailures"] = row["failures"]
                    mock.append(row)
                result["instrumentedMock"].append(path.relative_to(ROOT).as_posix())
            except Exception as error:
                for value in getattr(error, "rows", {}).values():
                    mock.append(_python(value))
                errors.append(f"behavior: candidate {path.relative_to(ROOT)}: {error}")
            result["observations"]["mock"] = merge_observations(mock)
            checkpoint()
        native = []
        for name in CANDIDATE_SCENARIOS:
            try:
                measured = audit.run(capture, executable, library, name,
                                     profile_spec(audit.scenarios()[name]), args.timeout,
                                     snapshot_path=candidate,
                                     output_name=name + "-snapshot-candidate", memory=name == "stress-clock")
                result["nativeMeasurements"][name] = measured
                if name == "stress-clock":
                    if "luaMemory" not in measured:
                        raise RuntimeError("native Lua allocator measurement is missing")
                    result["nativeMemory"] = measured["luaMemory"]
                native.extend(native_rows(name, measured, estimates))
                result["native"].append(name)
            except Exception as error:
                errors.append(f"native: candidate {name}: {error}")
            result["observations"]["native"] = merge_observations(native)
            checkpoint()
        if not discovery:
            try:
                measured = audit.run(capture, executable, library, "stress",
                                     dict(audit.scenarios()["stress"], instructionProfile=True), args.timeout,
                                     snapshot_path=candidate, output_name="stress-snapshot-behavior", memory=True)
                result["realTimeStress"] = {"luaMemory": measured["luaMemory"],
                                          "artifact": "build/scheduler-audit/stress-snapshot-behavior/results.json"}
                result["nativeMeasurements"]["stress-behavior"] = measured
            except Exception as error:
                errors.append(f"behavior: candidate real-time stress: {error}")
        result["observations"] = {"mock": merge_observations(mock), "native": merge_observations(native)}
        findings = check({"estimates": estimates, "record": record},
                         result["observations"],
                         set(record.get("requiredObservations", {}).values()),
                         updating=discovery, require_previous=False)
        result["warnings"] = [finding for finding in findings if finding.startswith("efficiency:")]
        errors.extend("candidate: " + finding for finding in findings
                      if not finding.startswith("efficiency:"))
        save_report(progress, {"errors": errors, "result": result})
    except (ValueError, TypeError, OSError) as error:
        errors.append(f"snapshot: candidate validation: {error}")
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
    return errors, result


def profile(audit, args):
    """A process-group watchdog bounds even a stuck Lua suite or simulator."""
    started = time.monotonic()
    deadline = started + PROFILE_SECONDS
    output = ROOT / "build/scheduler-audit/instruction-profile.json"
    output.parent.mkdir(parents=True, exist_ok=True)
    save_report(output, {"errors": ["profile: capture has not completed"],
                         "observations": {"mock": {}, "native": {}}})
    command = [sys.executable, str(ROOT / "tools/audit-scheduler.py"),
               "--snapshot" if args.snapshot else "--instructions",
               "--companion", str(args.companion), "--timeout", str(args.timeout),
               "--profile-deadline", str(deadline)]
    process = subprocess.Popen(command, cwd=ROOT, start_new_session=True)
    try:
        status = process.wait(timeout=max(0.001, deadline - time.monotonic()))
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait()
        report = json.loads(output.read_text(encoding="ascii"))
        pending = report.get("pendingCandidateProgress")
        if pending and (ROOT / pending).is_file():
            report["interruptedCandidate"] = json.loads((ROOT / pending).read_text(encoding="ascii"))
        report.setdefault("errors", []).append("time: five-minute profile deadline exceeded; snapshot unchanged")
        status = 1
    else:
        report = json.loads(output.read_text(encoding="ascii"))
    report["elapsedSeconds"] = time.monotonic() - started
    report["limitSeconds"] = PROFILE_SECONDS
    save_report(output, report)
    print(f"Instruction profile elapsed: {report['elapsedSeconds']:.3f}s (limit {PROFILE_SECONDS}s)")
    return status


def _profile(audit, args):
    """Fresh focused mock/native profile; incomplete evidence never writes a file."""
    snapshot = load()
    initial_sha = hashlib.sha256(SNAPSHOT.read_bytes()).hexdigest()
    def source_sha():
        digest = hashlib.sha256()
        for directory in ("src", "tests", "tools"):
            for path in sorted((ROOT / directory).rglob("*")):
                if path.is_file() and path.suffix in (".lua", ".py", ".cpp", ".yaml", ".yml", ".txt"):
                    digest.update(path.relative_to(ROOT).as_posix().encode("ascii"))
                    digest.update(path.read_bytes())
        return digest.hexdigest()
    inputs_sha = source_sha()
    runner = _module("instruction_test_runner", ROOT / "tests/run.py")
    errors, mock, native, declarations, native_measurements = [], [], [], {}, {}
    suites = [ROOT / name for name in MOCK_SUITES]
    output = ROOT / "build/scheduler-audit/instruction-profile.json"
    output.parent.mkdir(parents=True, exist_ok=True)
    def checkpoint():
        save_report(output, {
            "errors": errors + ["profile: capture/validation has not completed"],
            "observations": {"mock": merge_observations(mock), "native": merge_observations(native)},
            "declarations": declarations,
            "workSamples": work_samples,
            "nativeMeasurements": native_measurements,
            "coverage": {"mock": completed, "chartBehavior": chart_behavior},
        })
    completed, chart_behavior, chart_failures, work_samples = [], [], [], []
    for name in sorted(DEFERRED_SUITES):
        try:
            runner.run_test(ROOT / name)
            chart_behavior.append(name)
        except Exception as error:
            chart_failures.append(f"behavior: {name}: {error}")
    if chart_failures:
        print(f"Deferred Chart behavior failures: {len(chart_failures)} (assertions remain unchanged).")
        for failure in chart_failures:
            print(failure)
    for path in suites:
        try:
            rows, declared = runner.run_test(path, instructions=True, work_samples=work_samples)
            for value in rows.values():
                row = _python(value)
                # A passing behavioral suite has validated its negative cases.
                row["expectedFailures"] = row["failures"]
                mock.append(row)
            for key, maximum in declared.items():
                declarations[key] = max(declarations.get(key, 0), maximum)
            completed.append(path.relative_to(ROOT).as_posix())
        except Exception as error:
            for value in getattr(error, "rows", {}).values():
                mock.append(_python(value))
            for key, maximum in getattr(error, "declarations", {}).items():
                declarations[key] = max(declarations.get(key, 0), maximum)
            errors.append(f"behavior: {path.relative_to(ROOT)}: {error}")
        checkpoint()
    available = audit.scenarios()
    names = NATIVE_SCENARIOS
    checks, native_completed = {}, []
    try:
        library = args.companion / "Contents/Resources/libedgetx-tx16s-simulator.dylib"
        if not library.is_file():
            raise RuntimeError(f"native simulator library not found: {library}")
        executable, capture = audit.build_native(library), audit.capture_module()
        for name in dict.fromkeys(names):
            try:
                results = audit.run(capture, executable, library, name,
                                    profile_spec(available[name]), args.timeout)
                native_measurements[name] = results
                if name.startswith("hook-check"):
                    checks[name] = results
                else:
                    native.extend(native_rows(name, results, snapshot["estimates"]))
                native_completed.append(name)
            except Exception as error:
                errors.append(f"native: {name}: {error}")
            checkpoint()
            print(f"Native sample completed: {name}", flush=True)
        if len(checks) != 2:
            errors.append("safety: both native hook checks must complete")
        else:
            ok, message = audit.hook_check_status(checks["hook-check"], checks["hook-check-firmware"])
            if not ok:
                errors.append("safety: " + message)
    except Exception as error:
        errors.append("native: " + str(error))
    observations = {"mock": merge_observations(mock), "native": merge_observations(native)}
    required, coverage_errors = required_keys(snapshot, declarations)
    errors.extend(coverage_errors)
    if args.snapshot and not coverage_errors and required <= {
            key for rows in observations.values() for key in rows}:
        try:
            snapshot["estimates"] = propose(snapshot, observations, declarations, required)
        except ValueError as error:
            errors.append("snapshot: " + str(error))
    findings = check(snapshot, observations, required, updating=args.snapshot)
    warnings = [finding for finding in findings if finding.startswith("efficiency:")]
    errors.extend(finding for finding in findings if not finding.startswith("efficiency:"))
    if source_sha() != inputs_sha:
        errors.append("provenance: measurement inputs changed during the profile; refusing replacement")
    report = {"observations": observations, "errors": errors, "warnings": warnings,
              "chartFailures": chart_failures, "sourceSha": inputs_sha,
              "workSamples": work_samples, "nativeMeasurements": native_measurements,
              "requiredObservations": sorted(required),
              "declarations": declarations,
              "coverage": {"mock": completed, "chartBehavior": chart_behavior, "native": native_completed,
                           "requiredMock": [path.relative_to(ROOT).as_posix() for path in suites],
                           "requiredChartBehavior": sorted(DEFERRED_SUITES),
                           "requiredNative": list(dict.fromkeys(names))}}
    if warnings:
        print(f"Instruction spread review warnings: {len(warnings)} (all samples retained).")
    if errors:
        save_report(output, report)
        print(f"Instruction profile failed ({len(errors)} findings); snapshot unchanged. See {output}")
        for error in errors[:20]:
            print(error)
        return 1
    if args.snapshot:
        evidence = json.dumps(report, sort_keys=True, indent=2).encode("ascii") + b"\n"
        evidence_sha = hashlib.sha256(evidence).hexdigest()
        evidence_path = output.with_name(f"instruction-evidence-{evidence_sha}.json")
        evidence_path.write_bytes(evidence)
        estimates = snapshot["estimates"]
        record = snapshot["record"]
        for environment, previous in record["observations"].items():
            for key, row in previous.items():
                if deferred(snapshot, row):
                    observations[environment].setdefault(key, row)
        record.update(observations=observations,
                      requiredObservations=dict(enumerate(sorted(required), 1)),
                      coverage={key: dict(enumerate(values, 1)) for key, values in report["coverage"].items()},
                      warnings={index: finding for index, finding in enumerate(warnings, 1)},
                      environments={"mock": {"lua": "5.3", "runtime": "lupa"},
                                    "native": {"simulator": args.companion.name, "luaIntegerBits": 32}},
                      provenance={"profile": "five-minute focused mock/native",
                                  "evidence": evidence_path.relative_to(ROOT).as_posix(),
                                  "evidenceSha256": evidence_sha,
                                  "git": audit.subprocess.check_output(
                          ["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(), "sourceSha": inputs_sha})
        if "scheduler" in estimates["bounds"]:
            record["frameworkPolicy"] = {
                "scheduler": "Conservative coefficients, validated jointly against planner self-cost; "
                             "fixed reservation rounded to 500 and increased for measured shortfalls. "
                             "No independently measured component ranges."
            }
        record["coverage"]["candidateMock"] = dict(enumerate(MEMORY_SUITES, 1))
        record["coverage"]["candidateLua32Memory"] = {1: MEMORY_SUITES[0]}
        record["coverage"]["candidateNativeMemory"] = {1: "stress-clock", 2: "stress"}
        record["coverage"]["candidateChartBehavior"] = dict(enumerate(sorted(DEFERRED_SUITES), 1))
        record["coverage"]["candidateInstrumentedMock"] = dict(
            enumerate((path.relative_to(ROOT).as_posix() for path in suites), 1))
        record["coverage"]["candidateNative"] = dict(enumerate(CANDIDATE_SCENARIOS, 1))
        digest = hashlib.sha256(render(estimates, record).encode("ascii")).hexdigest()
        report["pendingCandidateProgress"] = f"build/scheduler-audit/candidate-progress-{digest}.json"
        save_report(output, report)
        discovery_errors, discovery_result = validate_candidate(
            audit, runner, args, estimates, record, executable, library, capture, suites, discovery=True)
        report["discovery"] = {"errors": discovery_errors, "result": discovery_result}
        if discovery_errors:
            errors.extend(discovery_errors)
            save_report(output, report)
            print(f"Candidate discovery failed; snapshot unchanged. See {output}")
            return 1
        for environment in ("mock", "native"):
            observations[environment] = merge_observations(
                list(observations[environment].values())
                + list(discovery_result["observations"][environment].values()))
        record["observations"] = observations
        report["observations"] = observations
        digest = hashlib.sha256(render(estimates, record).encode("ascii")).hexdigest()
        report["pendingCandidateProgress"] = f"build/scheduler-audit/candidate-progress-{digest}.json"
        save_report(output, report)
        candidate_errors, candidate_result = validate_candidate(
            audit, runner, args, estimates, record, executable, library, capture, suites)
        report["candidate"] = candidate_result
        errors.extend(candidate_errors)
        if source_sha() != inputs_sha:
            errors.append("provenance: measurement inputs changed during candidate validation; refusing replacement")
        if time.monotonic() >= args.profile_deadline:
            errors.append("time: five-minute deadline expired; refusing replacement")
        save_report(output, report)
        if errors:
            print(f"Snapshot candidate failed ({len(errors)} findings); snapshot unchanged. See {output}")
            for error in errors[:20]:
                print(error)
            return 1
        try:
            if candidate_result["sha256"] != hashlib.sha256(render(estimates, record).encode("ascii")).hexdigest():
                raise RuntimeError("candidate content changed after validation; refusing replacement")
            write(estimates, record, expected_sha=initial_sha, deadline=args.profile_deadline - 1)
        except (OSError, RuntimeError) as error:
            errors.append("publication: " + str(error))
            save_report(output, report)
            print(f"Snapshot publication failed; see {output}")
            return 1
        print("Instruction snapshot replaced after focused profile checks")
    else:
        save_report(output, report)
        print("Instruction regression profile passed")
    return 0

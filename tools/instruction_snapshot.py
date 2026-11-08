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
import tempfile

from lupa.lua53 import LuaRuntime, lua_type

ROOT = Path(__file__).resolve().parents[1]
SNAPSHOT = ROOT / "src/WIDGETS/AeroGrid/lib/instruction_snapshot.lua"
SCHEMA = 1
CEILING = 15000
MARGIN = 400
MIN_SAMPLES = 1
MEMORY_SUITES = (
    "tests/integration/widget/test_shared_module_code.lua",
    "tests/integration/widget/test_aircraft_memory.lua",
    "tests/integration/widget/test_output_memory.lua",
)
CANDIDATE_SCENARIOS = ("stress", "metric-16", "model-panels", "aircraft-link-recovery")


def target(maximum):
    """ceil10(1.1 * maximum), using exact integer arithmetic."""
    if type(maximum) is not int or not 0 <= maximum <= CEILING:
        raise ValueError(f"invalid measured maximum: {maximum!r}")
    return ((11 * maximum + 99) // 100) * 10


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
        return {"fixed": fixed, "perUnit": max(1, targets[1] - fixed)}
    fixed = max(0, max(budget - grant * per_unit for grant, budget in targets.items()))
    return {"fixed": fixed, "perUnit": per_unit}


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
                elif row["max"] > stage["fixed"] + stage["perUnit"] * row["grant"]:
                    findings.append(f"runtime: {environment}:{key} exceeds its declared bound")
                elif stage["fixed"] + stage["perUnit"] > CEILING - MARGIN:
                    findings.append(f"safety: {key} cannot fit beneath the ceiling and margin")
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


def write(estimates, record, path=SNAPSHOT, *, expected_sha):
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


def validate_candidate(audit, runner, args, estimates, record, executable, library, capture, suites):
    """Exercise the exact populated chunk without replacing the shipped snapshot."""
    errors = []
    result = {"mock": [], "chartBehavior": [], "chartFailures": [],
              "instrumentedMock": [], "native": [], "observations": {}}
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
        for name in MEMORY_SUITES:
            try:
                runner.run_test(ROOT / name, snapshot_path=candidate)
                result["mock"].append(name)
            except Exception as error:
                errors.append(f"memory: candidate {name}: {error}")
        for name in sorted(DEFERRED_SUITES):
            try:
                runner.run_test(ROOT / name, snapshot_path=candidate)
                result["chartBehavior"].append(name)
            except Exception as error:
                result["chartFailures"].append(f"behavior: candidate {name}: {error}")
        if errors:
            return errors, result
        mock = []
        for path in suites:
            try:
                rows, _ = runner.run_test(path, instructions=True, snapshot_path=candidate)
                for value in rows.values():
                    row = _python(value)
                    row["expectedFailures"] = row["failures"]
                    mock.append(row)
                result["instrumentedMock"].append(path.relative_to(ROOT).as_posix())
            except Exception as error:
                for value in getattr(error, "rows", {}).values():
                    mock.append(_python(value))
                errors.append(f"behavior: candidate {path.relative_to(ROOT)}: {error}")
        native = []
        for name in CANDIDATE_SCENARIOS:
            try:
                measured = audit.run(capture, executable, library, name,
                                     dict(audit.scenarios()[name], instructionProfile=True), args.timeout,
                                     snapshot_path=candidate,
                                     output_name=name + "-snapshot-candidate")
                native.extend(native_rows(name, measured, estimates))
                result["native"].append(name)
            except Exception as error:
                errors.append(f"native: candidate {name}: {error}")
        result["observations"] = {"mock": merge_observations(mock), "native": merge_observations(native)}
        findings = check({"estimates": estimates, "record": record},
                         result["observations"],
                         set(), updating=False, require_previous=False)
        errors.extend("candidate: " + finding for finding in findings
                      if not finding.startswith("efficiency:"))
    except (ValueError, TypeError, OSError) as error:
        errors.append(f"snapshot: candidate validation: {error}")
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
    return errors, result


def profile(audit, args):
    """Fresh full mock/native profile; incomplete evidence never writes a file."""
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
    errors, mock, native, declarations = [], [], [], {}
    suites = [path for path in sorted((ROOT / "tests").rglob("test_*.lua"))
              if "support" not in path.relative_to(ROOT).parts
              and path.relative_to(ROOT).as_posix() not in DEFERRED_SUITES]
    completed, chart_behavior, chart_failures = [], [], []
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
            rows, declared = runner.run_test(path, instructions=True)
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
    available = audit.scenarios()
    names = ["hook-check", "hook-check-firmware", "stress", "metric-16", "model-panels",
             "flight-smart-tasks", "flight-owner-handoff", "session-reset", "aircraft-link-recovery"]
    names.extend(name for name in available if name.startswith("lifecycle-app"))
    # Panel extrema supply native stages missed by ordinary dashboard releases.
    names.extend(name for name in available if name.endswith(("-min", "-max"))
                 and not name.startswith("chart-"))
    names.append("theme-showcase-tasks")
    names.extend(("theme-resolution-corrections", "shared-flight-loading", "layout-loading-error",
                  "flight-registration-error"))
    # Existing foreground scenarios exercise the actual staged work and its
    # behavioral assertions, rather than measuring workBound getters.
    names.extend((
        "modal-log", "modal-location", "modal-menu", "modal-settings-save",
        "modal-settings-save-output", "modal-settings-publication-error",
        "modal-settings-open-primary", "modal-settings-open-recovered",
        "modal-settings-open-missing", "modal-settings-open-legacy-one",
        "modal-settings-open-legacy-conflict", "modal-settings-open-invalid",
        "modal-settings-open-retirement", "modal-settings-close-return",
        "editor-drawer-large-config", "editor-list-large-states",
        "editor-list-remove-panel", "editor-list-append-error",
        "editor-add-crowded-metric", "editor-list-return", "editor-list-cancel",
        "editor-write-error", "editor-write-picker-error", "editor-save-registration", "editor-input-keys",
        "editor-input-tap", "editor-input-add", "editor-input-cancel",
        "editor-drag-move-crowded", "editor-drag-resize-crowded",
        "lifecycle-cancel", "lifecycle-settings-drain", "lifecycle-menu-close",
        "lifecycle-admission-background", "lifecycle-preparation",
        "lifecycle-retire-admission-16",
    ))
    names.extend(name for name in available
                 if name.startswith(("editor-drawer-", "editor-entry-", "editor-write-entry-"))
                 and "chart" not in name)
    names.extend(name for name in available if name.startswith("panel-reflow-") and "chart" not in name)
    names.extend(name for name in available if name.startswith("editor-drag-move-")
                 and "chart" not in name and not name.endswith("-quick"))
    checks, native_completed = {}, []
    try:
        library = args.companion / "Contents/Resources/libedgetx-tx16s-simulator.dylib"
        if not library.is_file():
            raise RuntimeError(f"native simulator library not found: {library}")
        executable, capture = audit.build_native(library), audit.capture_module()
        for name in dict.fromkeys(names):
            try:
                results = audit.run(capture, executable, library, name,
                                    dict(available[name], instructionProfile=True), args.timeout)
                if name.startswith("hook-check"):
                    checks[name] = results
                else:
                    native.extend(native_rows(name, results, snapshot["estimates"]))
                native_completed.append(name)
            except Exception as error:
                errors.append(f"native: {name}: {error}")
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
              "requiredObservations": sorted(required),
              "declarations": declarations,
              "coverage": {"mock": completed, "chartBehavior": chart_behavior, "native": native_completed,
                           "requiredMock": [path.relative_to(ROOT).as_posix() for path in suites],
                           "requiredChartBehavior": sorted(DEFERRED_SUITES),
                           "requiredNative": list(dict.fromkeys(names))}}
    output = ROOT / "build/scheduler-audit/instruction-profile.json"
    output.parent.mkdir(parents=True, exist_ok=True)
    if warnings:
        print(f"Instruction spread review warnings: {len(warnings)} (all samples retained).")
    if errors:
        output.write_text(json.dumps(report, indent=2) + "\n", encoding="ascii")
        print(f"Instruction profile failed ({len(errors)} findings); snapshot unchanged. See {output}")
        for error in errors[:20]:
            print(error)
        return 1
    if args.snapshot:
        estimates = snapshot["estimates"]
        record = snapshot["record"]
        for environment, previous in record["observations"].items():
            for key, row in previous.items():
                if deferred(snapshot, row):
                    observations[environment].setdefault(key, row)
        record.update(observations=observations,
                      coverage={key: dict(enumerate(values, 1)) for key, values in report["coverage"].items()},
                      warnings={index: finding for index, finding in enumerate(warnings, 1)},
                      environments={"mock": {"lua": "5.3", "runtime": "lupa"},
                                    "native": {"simulator": args.companion.name, "luaIntegerBits": 32}},
                      provenance={"profile": "full mock/native", "git": audit.subprocess.check_output(
                          ["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(), "sourceSha": inputs_sha})
        if "scheduler" in estimates["bounds"]:
            record["frameworkPolicy"] = {
                "scheduler": "Conservative coefficients, validated jointly against planner self-cost; "
                             "only fixed reservation increases to cover a measured shortfall. "
                             "No independently measured component ranges."
            }
        record["coverage"]["candidateMock"] = dict(enumerate(MEMORY_SUITES, 1))
        record["coverage"]["candidateChartBehavior"] = dict(enumerate(sorted(DEFERRED_SUITES), 1))
        record["coverage"]["candidateInstrumentedMock"] = dict(
            enumerate((path.relative_to(ROOT).as_posix() for path in suites), 1))
        record["coverage"]["candidateNative"] = dict(enumerate(CANDIDATE_SCENARIOS, 1))
        candidate_errors, report["candidate"] = validate_candidate(
            audit, runner, args, estimates, record, executable, library, capture, suites)
        candidate_chart_failures = report["candidate"].get("chartFailures", [])
        if candidate_chart_failures:
            print(f"Deferred candidate Chart behavior failures: {len(candidate_chart_failures)}.")
            for failure in candidate_chart_failures:
                print(failure)
        errors.extend(candidate_errors)
        if source_sha() != inputs_sha:
            errors.append("provenance: measurement inputs changed during candidate validation; refusing replacement")
        output.write_text(json.dumps(report, indent=2) + "\n", encoding="ascii")
        if errors:
            print(f"Snapshot candidate failed ({len(errors)} findings); snapshot unchanged. See {output}")
            for error in errors[:20]:
                print(error)
            return 1
        write(estimates, record, expected_sha=initial_sha)
        print("Instruction snapshot replaced after full profile checks")
    else:
        output.write_text(json.dumps(report, indent=2) + "\n", encoding="ascii")
        print("Instruction regression profile passed")
    return 0

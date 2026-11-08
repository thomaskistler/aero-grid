# SPDX-License-Identifier: GPL-2.0-only

import copy
import hashlib
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import instruction_snapshot as snapshot


class InstructionSnapshotTests(unittest.TestCase):
    def row(self, **changes):
        row = dict(kind="task", name="test", stage="run", grant=1, n=5,
                   min=100, max=200, failures=0, minScenario="cheap", maxScenario="work")
        row.update(changes)
        return row

    def data(self):
        row = self.row()
        key = snapshot.observation_key(row)
        observations = {environment: {key: copy.deepcopy(row)} for environment in ("mock", "native")}
        data = {"estimates": {"tasks": {"test": {"run": {"fixed": 0, "perUnit": 220}}},
                              "bounds": {}},
                "record": {"schema": 1, "deferred": {}, "observations": copy.deepcopy(observations)}}
        return data, observations, {key}

    def test_target_exact_rounding(self):
        for maximum in range(15001):
            value = snapshot.target(maximum)
            self.assertEqual(value % 10, 0)
            self.assertGreaterEqual(value * 10, maximum * 11)
            if value:
                self.assertLess((value - 10) * 10, maximum * 11)
        self.assertEqual(snapshot.target(100), 110)
        self.assertEqual(snapshot.target(101), 120)

    def test_strict_spread_thresholds(self):
        self.assertFalse(snapshot.spread(400, 700))  # difference == 300
        self.assertFalse(snapshot.spread(800, 1200))  # ratio == 1.5
        self.assertTrue(snapshot.spread(799, 1200))
        self.assertTrue(snapshot.spread(0, 301))
        self.assertFalse(snapshot.spread(0, 300))

    def test_scheduler_estimates_are_preserved_and_validated_jointly(self):
        data, observations, required = self.data()
        data["estimates"]["bounds"]["scheduler"] = {"fixed": 196, "examine": 64, "run": 224}
        for environment in observations:
            for stage, maximum in (("0:0", 134), ("10:4", 1732)):
                row = self.row(kind="framework", name="scheduler", stage=stage, grant=0,
                               min=maximum, max=maximum, n=1)
                observations[environment][snapshot.observation_key(row)] = row
        keys, errors = snapshot.required_keys(data, {"test|run": 1})
        self.assertFalse(errors)
        self.assertIn("framework|scheduler|0:0|0", keys)
        self.assertFalse(any(key.startswith("bound|scheduler|") for key in keys))
        self.assertEqual(snapshot.check(data, observations, keys, updating=True), [])
        proposed = snapshot.propose(data, observations, {"test|run": 1}, keys)
        self.assertEqual(proposed["bounds"]["scheduler"], data["estimates"]["bounds"]["scheduler"])
        observations["native"]["framework|scheduler|10:4|0"]["max"] = 1733
        self.assertTrue(any("joint framework charge 1732" in finding
                            for finding in snapshot.check(data, observations, keys, updating=True)))
        proposed = snapshot.propose(data, observations, {"test|run": 1}, keys)
        self.assertEqual(proposed["bounds"]["scheduler"], {"fixed": 220, "examine": 64, "run": 224})

    def test_measured_incremental_growth_fitting(self):
        # Raw maxima yielding conservative targets 300, 500 and 700.
        self.assertEqual(snapshot.fit({1: 270, 2: 450, 3: 630}),
                         {"fixed": 100, "perUnit": 200})
        grants = {1: 103, 2: 302, 3: 310, 4: 450}
        fitted = snapshot.fit(grants)
        for grant, maximum in grants.items():
            self.assertGreaterEqual(fitted["fixed"] + fitted["perUnit"] * grant, snapshot.target(maximum))
        self.assertGreater(fitted["perUnit"], 0)
        self.assertEqual(snapshot.fit({1: 100}), {"fixed": 0, "perUnit": 110})
        with self.assertRaises(ValueError):
            snapshot.fit({2: 100})

    def test_one_real_sample_suffices_without_repetition_padding(self):
        data, observations, required = self.data()
        next(iter(observations["mock"].values()))["n"] = 1
        observations["native"] = {
            "callback|refresh|dense|0": self.row(kind="callback", name="refresh", stage="dense", grant=0, n=1)
        }
        data["record"]["observations"]["native"] = copy.deepcopy(observations["native"])
        self.assertEqual(snapshot.check(data, observations, required), [])
        observations["mock"] = {}
        self.assertTrue(any("coverage: missing task" in finding for finding in snapshot.check(data, observations, required)))

    def test_zero_grant_noops_are_retained_and_covered_by_fixed_charge(self):
        self.assertEqual(snapshot.fit({0: 5, 1: 100}), {"fixed": 10, "perUnit": 100})
        self.assertEqual(snapshot.fit({0: 120, 1: 270, 2: 450, 3: 630}),
                         {"fixed": 140, "perUnit": 200})
        data, observations, required = self.data()
        noop = self.row(grant=0, min=5, max=5)
        observations["mock"][snapshot.observation_key(noop)] = noop
        proposed = snapshot.propose(data, observations, {"test|run": 1}, required)
        self.assertEqual(proposed["tasks"]["test"]["run"], {"fixed": 10, "perUnit": 210})
        self.assertEqual(snapshot.check({"estimates": proposed, "record": data["record"]},
                                        observations, required, updating=True), [])
        with self.assertRaises(ValueError):
            snapshot.fit({-1: 5, 1: 100})

    def test_any_increase_fails_and_update_does_not_hide_safety(self):
        data, observations, required = self.data()
        row = next(iter(observations["native"].values()))
        row["max"] = 201
        self.assertTrue(any("regression:" in finding for finding in snapshot.check(data, observations, required)))
        self.assertEqual(snapshot.check(data, observations, required, updating=True), [])
        row["max"] = 15001
        findings = snapshot.check(data, observations, required, updating=True)
        for category in ("safety:", "runtime:", "efficiency:"):
            self.assertTrue(any(category in finding for finding in findings))

    def test_missing_environment_entry_and_behavior_fail(self):
        data, observations, required = self.data()
        observations["native"] = {}
        self.assertTrue(any("mock AND native" in finding for finding in snapshot.check(data, observations, required)))
        observations["mock"] = {}
        self.assertTrue(any("coverage: missing" in finding for finding in snapshot.check(data, observations, required)))
        data, observations, required = self.data()
        next(iter(observations["mock"].values()))["failures"] = 1
        self.assertTrue(any("behavior:" in finding for finding in snapshot.check(data, observations, required)))

    def test_merge_keeps_noops_and_environment_extrema(self):
        rows = snapshot.merge_observations([self.row(), self.row(min=1, max=99, n=10)])
        row = next(iter(rows.values()))
        self.assertEqual((row["n"], row["min"], row["max"]), (15, 1, 200))
        with self.assertRaises(ValueError):
            snapshot.merge_observations([self.row(n=0)])

    def test_previously_observed_environment_cannot_disappear(self):
        data, observations, required = self.data()
        key = next(iter(observations["native"]))
        observations["native"].pop(key)
        other = self.row(kind="callback", name="refresh", stage="other", grant=0)
        observations["native"][snapshot.observation_key(other)] = other
        for updating in (False, True):
            findings = snapshot.check(data, observations, required, updating=updating)
            self.assertTrue(any(f"coverage: missing previously recorded native:{key}" == finding
                                for finding in findings))
        self.assertFalse(any("missing previously recorded" in finding
                             for finding in snapshot.check(data, observations, required, require_previous=False)))
        data["record"]["deferred"]["test"] = "deferred"
        self.assertFalse(any("missing previously recorded" in finding
                             for finding in snapshot.check(data, observations, set(), updating=True)))

    def test_expected_errors_remain_observations(self):
        data, observations, required = self.data()
        row = next(iter(observations["mock"].values()))
        row["failures"] = row["expectedFailures"] = 2
        self.assertEqual(snapshot.check(data, observations, required), [])
        merged = snapshot.merge_observations([row, row])
        self.assertEqual(next(iter(merged.values()))["expectedFailures"], 4)

    def test_proposal_uses_higher_environment_maximum(self):
        data, observations, required = self.data()
        next(iter(observations["native"].values()))["max"] = 210
        candidate = snapshot.propose(data, observations, {"test|run": 1}, required)
        self.assertEqual(candidate["tasks"]["test"]["run"], {"fixed": 0, "perUnit": 240})
        self.assertEqual(data["estimates"]["tasks"]["test"]["run"]["perUnit"], 220)
        with self.assertRaises(ValueError):
            snapshot.propose(data, observations, {"test|run": 1}, required | {"task|test|run|2"})

    def test_task_table_shows_min_current_bound_max_and_missing_grants(self):
        data, observations, required = self.data()
        next(iter(observations["native"].values())).update(min=110, max=210)
        measurement = {"observations": observations, "requiredObservations": sorted(required | {"task|test|run|2"}),
                       "errors": []}
        rows = snapshot.task_rows(data, measurement)
        self.assertEqual((rows[0]["min"], rows[0]["curr"], rows[0]["max"]), (100, 220, 210))
        self.assertEqual((rows[0]["mock_n"], rows[0]["native_n"], rows[0]["samples"]), (5, 5, 10))
        self.assertEqual(rows[1]["curr"], 440)
        self.assertIsNone(rows[1]["min"])
        self.assertIn("UNMEASURED", rows[1]["status"])

    def test_required_keys_preserve_prior_observations_except_deferred_tasks(self):
        data, observations, required = self.data()
        callback = self.row(kind="callback", name="refresh", stage="dense", grant=0)
        callback_key = snapshot.observation_key(callback)
        chart = self.row(name="panel.chart")
        chart_key = snapshot.observation_key(chart)
        data["record"]["observations"]["native"].update({callback_key: callback, chart_key: chart})
        data["record"]["deferred"]["panel.chart"] = "measurement deferred"
        keys, errors = snapshot.required_keys(data, {"test|run": 1})
        self.assertEqual(errors, [])
        self.assertEqual(keys, required | {callback_key})

    def test_native_foreground_attribution_keeps_nested_work_separate(self):
        estimates = snapshot.load()["estimates"]
        labels = {
            "host:overhead:steady": ("host-overhead", "steady", 120, 200),
            "host:head:reset": ("host", "reset", 120, 200),
            "host:head:handoff": ("host", "handoff", 120, 200),
            "host:overhead:host-reconcile": ("host-overhead", "host-reconcile", 120, 200),
            "scheduler:ready:panel-enroll": ("host", "panelEnroll", 120, 200),
            "scheduler:ready:service-enroll": ("host", "serviceEnroll", 120, 200),
            "scheduler:ready:panel-only:scan": ("host", "reconcile", 120, 200),
            "modal:settings:load:read": ("settings-store-load", "read", 120, 200),
            "modal:settings:load:start": ("settings-store-load", "start", 120, 200),
            "main:flightJob:registration": ("main", "registrationOverhead", 20, 40),
            "main:flightJob:error": ("main", "flightError", 20, 40),
            "modal:settings:store:serialize": ("settings-store-save", "serialize", 120, 200),
            "modal:settings:advance:load_read:idle": ("settings-ui", "storeOverhead", 20, 40),
            "modal:settings:advance:save_serialize:idle": ("settings-ui", "storeOverhead", 20, 40),
            "modal:settings:advance:load_legacy:idle": ("settings-ui-load", "legacy", 120, 200),
            "editor:drawer:advance:build:source": ("editor-drawer", "build", 120, 200),
            "editor:advanceEditor:drag:settings": ("editor-drag", "settings", 120, 200),
            "editor:advanceEditor:drawer-open:configure": ("editor-drawer-open", "configure", 120, 200),
            "editor:advanceEditor:layout:visit": ("editor-layout", "visit", 120, 200),
            "editor:advanceEditor:render:6": ("editor-render", "finish", 120, 200),
            "editor:advanceEditor:build:2": ("main", "editorBuild", 120, 200),
            "modal:location:handle:idle": ("main", "modalLocation", 120, 200),
            "editor:input:bound:tap": ("editor-input", "tap", 120, 200),
            "modal:log:advance:wrap": ("log-viewer", "wrap", 120, 200),
            "load:theme-publish:commit": ("dashboard-loader", "theme-publish", 120, 200),
            "registration:advance:arms": ("flight-registration", "arms", 120, 200),
            "lifecycle:advanceReflow:metric:begin": ("panel-reflow", "metric", 120, 200),
            "lifecycle:retirePage:panel:metric": ("dashboard-lifecycle", "panel", 120, 200),
            "lifecycle:retirePage:settings": ("dashboard-lifecycle", "settingsAbsent", 120, 200),
            "lifecycle:retirePage:settings:closing": ("dashboard-lifecycle", "settingsDrain", 120, 200),
            "lifecycle:waitReflow": ("dashboard-lifecycle", "reflowWait", 20, 40),
        }
        bucket = dict(n=10, min=120, max=200, selfMin=20, selfMax=40)
        for label, expected in labels.items():
            rows = snapshot.native_rows("focused", {"stats": {label: {"units": {"1": bucket}}}}, estimates)
            self.assertEqual(len(rows), 2 if expected[1] == "settingsDrain" else 1, label)
            row = rows[0]
            self.assertEqual((row["name"], row["stage"], row["min"], row["max"]), expected, label)
            self.assertEqual((row["kind"], row["grant"], row["n"]), ("bound", 0, 10))
            if expected[1] == "settingsDrain":
                self.assertEqual((rows[1]["stage"], rows[1]["min"], rows[1]["max"]),
                                 ("settingsDrainOverhead", 20, 40))
        with self.assertRaises(ValueError):
            snapshot.native_rows("focused", {"stats": {"modal:settings:advance:load_read:idle": {
                "units": {"1": dict(n=10, min=120, max=200, selfMax=40)}}}}, estimates)
        self.assertIsNone(snapshot.native_bound("modal:settings:load:not-a-stage", estimates))
        self.assertIsNone(snapshot.native_bound("scheduler:ready:settled", estimates))
        self.assertIsNone(snapshot.native_bound("main:flightJob:idle", estimates))
        rows = snapshot.native_rows("focused", {"stats": {
            "scheduler:framework:10:4": {"units": {"1": bucket}}}}, estimates)
        self.assertEqual((rows[0]["kind"], rows[0]["stage"], rows[0]["min"], rows[0]["max"]),
                         ("framework", "10:4", 20, 40))

    def test_full_profile_retains_spread_as_review_warning_without_blocking_write(self):
        row = self.row(name="model", n=1, min=100, max=700)
        key = snapshot.observation_key(row)
        data = {
            "estimates": {"tasks": {"model": {"run": {"fixed": 0, "perUnit": 800}}}, "bounds": {}},
            "record": {"schema": 1, "deferred": {}, "observations": {"mock": {}, "native": {}}},
        }
        runner = SimpleNamespace(run_test=lambda *args, **kwargs: ({key: row}, {"model|run": 1}))
        class Scenarios(dict):
            def __missing__(self, key):
                return {}
        native = {"stats": {"task:service:model:run": {"units": {"1": {
            "n": 1, "min": 100, "max": 700,
        }}}}}
        audit = SimpleNamespace(
            scenarios=Scenarios, build_native=lambda library: "native",
            capture_module=lambda: None,
            run=lambda *args, **kwargs: copy.deepcopy(native),
            hook_check_status=lambda *args: (True, "hook agreement"),
            subprocess=SimpleNamespace(check_output=lambda *args, **kwargs: "commit\n"),
        )
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "tests").mkdir()
            (root / "tests/test_profile.lua").write_text("return true\n")
            path = root / "snapshot.lua"
            path.write_text("seed")
            companion = root / "Companion.app"
            library = companion / "Contents/Resources/libedgetx-tx16s-simulator.dylib"
            library.parent.mkdir(parents=True)
            library.touch()
            args = SimpleNamespace(companion=companion, snapshot=True, timeout=120)
            with patch.object(snapshot, "ROOT", root), patch.object(snapshot, "SNAPSHOT", path), \
                    patch.object(snapshot, "load", side_effect=lambda: copy.deepcopy(data)), \
                    patch.object(snapshot, "_module", return_value=runner), \
                    patch.object(snapshot, "write") as write:
                with patch.object(audit, "run", wraps=audit.run) as runs, \
                        patch.object(runner, "run_test", wraps=runner.run_test) as mock_runs:
                    self.assertEqual(snapshot.profile(audit, args), 0)
                names = [call.kwargs.get("output_name") or call.args[3] for call in runs.call_args_list]
                self.assertIn("aircraft-link-recovery", names)
                self.assertIn("aircraft-link-recovery-snapshot-candidate", names)
                recorded_chart = [
                    call for call in mock_runs.call_args_list
                    if call.args[0].relative_to(root).as_posix() in snapshot.DEFERRED_SUITES
                ]
                self.assertEqual(len(recorded_chart), 2 * len(snapshot.DEFERRED_SUITES))
                self.assertTrue(all(not call.kwargs.get("instructions") for call in recorded_chart))
                write.assert_called_once()
                estimates, record = write.call_args.args
                self.assertEqual(estimates["tasks"]["model"]["run"]["perUnit"], 770)
                self.assertTrue(all(finding.startswith("efficiency:") for finding in record["warnings"].values()))
                self.assertEqual(record["observations"]["mock"][key]["min"], 100)
                snapshot.render(estimates, record)
                write.reset_mock()
                def fail_chart(path, **kwargs):
                    if path.relative_to(root).as_posix() in snapshot.DEFERRED_SUITES:
                        raise RuntimeError("chart did not draw")
                    return {key: row}, {"model|run": 1}
                with patch.object(runner, "run_test", side_effect=fail_chart), \
                        patch.object(audit, "run", wraps=audit.run) as runs:
                    self.assertEqual(snapshot.profile(audit, args), 1)
                    runs.assert_not_called()
                    report = (root / "build/scheduler-audit/instruction-profile-preflight.json").read_text()
                    self.assertIn("chart did not draw", report)
                    candidate_errors, result = snapshot.validate_candidate(
                        audit, runner, args, estimates, record, "native", library, None,
                        [root / "tests/test_profile.lua"])
                    runs.assert_not_called()
                self.assertEqual(len([finding for finding in candidate_errors
                                      if finding.startswith("behavior: candidate")]),
                                 len(snapshot.DEFERRED_SUITES))
                self.assertEqual(result["chartBehavior"], [])
                write.assert_not_called()
                with patch.object(runner, "run_test", side_effect=RuntimeError("heap bound exceeded")):
                    candidate_errors, result = snapshot.validate_candidate(
                        audit, runner, args, estimates, record, "native", library, None,
                        [root / "tests/test_profile.lua"])
                self.assertEqual(len([finding for finding in candidate_errors if finding.startswith("memory:")]), 3)
                self.assertEqual(result["mock"], [])
                self.assertFalse(list((root / "build/scheduler-audit").glob("snapshot-candidate-*.lua")))
                increased = copy.deepcopy(native)
                increased["stats"]["task:service:model:run"]["units"]["1"]["max"] = 701
                with patch.object(audit, "run", return_value=increased):
                    candidate_errors, _ = snapshot.validate_candidate(
                        audit, runner, args, estimates, record, "native", library, None,
                        [root / "tests/test_profile.lua"])
                self.assertTrue(any("regression:" in finding for finding in candidate_errors))
                increased_mock = dict(row, max=701)
                def mock_regression(*args, **kwargs):
                    if kwargs.get("instructions"):
                        return {key: increased_mock}, {"model|run": 1}
                    return None
                with patch.object(runner, "run_test", side_effect=mock_regression):
                    candidate_errors, candidate_result = snapshot.validate_candidate(
                        audit, runner, args, estimates, record, "native", library, None,
                        [root / "tests/test_profile.lua"])
                self.assertTrue(any("regression: mock:" in finding for finding in candidate_errors))
                self.assertEqual(candidate_result["observations"]["mock"][key]["max"], 701)
                increased_mock["max"] = 15001
                with patch.object(runner, "run_test", side_effect=mock_regression):
                    candidate_errors, _ = snapshot.validate_candidate(
                        audit, runner, args, estimates, record, "native", library, None,
                        [root / "tests/test_profile.lua"])
                self.assertTrue(any("safety: mock:" in finding for finding in candidate_errors))
                self.assertTrue(any("runtime: mock:" in finding for finding in candidate_errors))
                def fail_recovery(*args, **kwargs):
                    if kwargs.get("output_name") == "aircraft-link-recovery-snapshot-candidate":
                        raise RuntimeError("link did not recover")
                    return copy.deepcopy(native)
                with patch.object(audit, "run", side_effect=fail_recovery):
                    self.assertEqual(snapshot.profile(audit, args), 1)
                    report = (root / "build/scheduler-audit/instruction-profile.json").read_text()
                    self.assertIn("link did not recover", report)
                write.assert_not_called()
                with patch.object(snapshot, "validate_candidate", return_value=(
                        ["memory: heap bound exceeded"], {"mock": [], "native": []})):
                    self.assertEqual(snapshot.profile(audit, args), 1)
                write.assert_not_called()
                row["max"] = 15001
                self.assertEqual(snapshot.profile(audit, args), 1)
                write.assert_not_called()

    def test_native_aircraft_recovery_scenario_preserves_deadline(self):
        audit = snapshot._module("audit_scheduler_scenario", snapshot.ROOT / "tools/audit-scheduler.py")
        scenario = audit.scenarios()["aircraft-link-recovery"]
        self.assertEqual(scenario["expected"], 9)
        self.assertTrue(scenario["deterministicClock"])
        self.assertEqual(scenario["sources"], ["RxBt", "RQly", "1RSS", "RFMD", "Alt", "Alt+", "VSpd+"])
        self.assertEqual(
            [(phase["name"], phase["callbacks"], phase["step"]) for phase in scenario["phases"]],
            [("warm", 200, 20), ("loss", 40, 20), ("check-loss", 1, 20),
             ("recovery", 40, 20), ("check-recovery", 1, 20)],
        )

    def test_native_profile_charges_observed_cost_without_applying_margin_twice(self):
        source = (snapshot.ROOT / "tools/scheduler-audit/probe.lua").read_text(encoding="ascii")
        functions = source.split("local function fit(cost)\n", 1)[1].split("\nlocal function gate(", 1)[0]
        lua = snapshot.LuaRuntime(unpack_returned_tuples=True)
        charge = lua.execute(
            "local config = ...\nlocal function fit(cost)\n" + functions + "\nreturn charge",
            lua.table_from({"instructionProfile": True}),
        )
        self.assertEqual(charge(1223), 1223)
        self.assertLessEqual(charge(1223), 1340)
        self.assertGreater(charge(1341), 1340)
        legacy = lua.execute(
            "local config = ...\nlocal function fit(cost)\n" + functions + "\nreturn charge",
            lua.table_from({"instructionProfile": False}),
        )
        self.assertEqual(legacy(1223), 1350)

    def test_selected_mock_suite_uses_exact_candidate(self):
        runner = snapshot._module("snapshot_cli_runner", snapshot.ROOT / "tests/run.py")
        suite = snapshot.ROOT / "tests/unit/lib/test_scheduler.lua"
        with tempfile.TemporaryDirectory() as directory:
            candidate = Path(directory) / "candidate.lua"
            candidate.write_text("return true\n", encoding="ascii")
            with patch.object(sys, "argv", ["run.py", "--snapshot", str(candidate), str(suite)]), \
                    patch.object(runner, "run_test") as run:
                runner.main()
            run.assert_called_once_with(suite, snapshot_path=candidate.resolve())

    def test_selected_native_candidate_preserves_scenario_identity(self):
        audit = snapshot._module("audit_scheduler_cli", snapshot.ROOT / "tools/audit-scheduler.py")
        with tempfile.TemporaryDirectory() as directory:
            candidate = Path(directory) / "candidate.lua"
            candidate.write_text("return true\n", encoding="ascii")
            companion = Path(directory) / "Companion.app"
            library = companion / "Contents/Resources/libedgetx-tx16s-simulator.dylib"
            library.parent.mkdir(parents=True)
            library.touch()
            args = ["audit-scheduler.py", "--candidate", str(candidate),
                    "--companion", str(companion), "aircraft-link-recovery"]
            with patch.object(sys, "argv", args), patch.object(audit.platform, "system", return_value="Darwin"), \
                    patch.object(audit, "build_native", return_value="native"), \
                    patch.object(audit, "capture_module", return_value=None), \
                    patch.object(audit, "run", return_value={"stats": {}, "panels": 9}) as run:
                self.assertEqual(audit.main(), 0)
            self.assertEqual(run.call_args.args[3], "aircraft-link-recovery")
            self.assertTrue(run.call_args.args[4]["instructionProfile"])
            self.assertEqual(run.call_args.kwargs["snapshot_path"], candidate)
            self.assertEqual(run.call_args.kwargs["output_name"], "aircraft-link-recovery-snapshot-candidate")

    def test_candidate_is_loaded_instead_of_the_shipped_snapshot(self):
        runner = snapshot._module("snapshot_override_runner", snapshot.ROOT / "tests/run.py")
        data = snapshot.load()
        data["record"]["candidateMarker"] = True
        with tempfile.TemporaryDirectory() as directory:
            candidate, suite = Path(directory) / "candidate.lua", Path(directory) / "test_candidate.lua"
            candidate.write_text(snapshot.render(**data), encoding="ascii")
            copied = Path(directory) / "build/test-widget-fixture/lib/instruction_snapshot.lua"
            copied.parent.mkdir(parents=True)
            seed = copy.deepcopy(data)
            seed["record"].pop("candidateMarker")
            copied.write_text(snapshot.render(**seed), encoding="ascii")
            suite.write_text("""
                local root = ...
                local chunk = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/instruction_snapshot.lua"))()
                assert(chunk("record").candidateMarker, "candidate was not loaded")
            """ + f"""
                local copied = assert(loadfile("{copied.as_posix()}"))()
                assert(copied("record").candidateMarker, "runtime fixture still loaded the copied seed")
            """, encoding="ascii")
            runner.run_test(suite, snapshot_path=candidate)

    def test_native_loading_callbacks_are_not_omitted_from_safety_checks(self):
        data, observations, _ = self.data()
        measured = snapshot.native_rows("dense", {"stats": {
            "callback:refresh@load": {"units": {"1": {"n": 1, "min": 15001, "max": 15001}}}}})
        self.assertEqual((measured[0]["name"], measured[0]["stage"]), ("refresh", "dense:load:"))
        observations["native"] = snapshot.merge_observations(measured)
        self.assertTrue(any(finding.startswith("safety:") for finding in
                            snapshot.check(data, observations, set(), updating=True)))

    def test_native_action_refreshes_are_separate_safety_observations(self):
        audit = snapshot._module("audit_scheduler_actions", snapshot.ROOT / "tools/audit-scheduler.py")
        probe = (snapshot.ROOT / "tools/scheduler-audit/probe.lua").read_text(encoding="ascii")
        action_table = probe.split("local refreshActions = ", 1)[1].split("\n\nlocal function advance", 1)[0]
        declared = snapshot._python(snapshot.LuaRuntime().execute("return " + action_table))
        self.assertEqual(declared, audit.ACTION_REFRESH_COUNTS)
        self.assertNotIn("refreshFn(context,", probe)
        actions = ["open-location", "open-location", "close-location", "check-log"]
        counts = {
            "callback:action:open-location": {"n": 2},
            "callback:action:close-location": {"n": 1},
            "callback:action:check-log": {"n": 1},
            "callback:refresh:action:open-location": {"n": 4},
            "callback:refresh:action:close-location": {"n": 1},
        }
        audit.check_action_coverage("modal", actions, counts)
        counts["callback:refresh:action:open-location"]["n"] = 3
        with self.assertRaisesRegex(RuntimeError, "missing separately measured refresh callbacks"):
            audit.check_action_coverage("modal", actions, counts)
        bucket = dict(n=4, min=1400, max=15001, selfMin=300, selfMax=500)
        rows = snapshot.native_rows("modal", {"stats": {
            "callback:refresh:action:open-location": {"units": {"1": bucket}},
            "callback:action:open-location": {"units": {"1": bucket}},
        }})
        self.assertEqual(len(rows), 1)
        self.assertEqual((rows[0]["kind"], rows[0]["name"], rows[0]["stage"], rows[0]["max"]),
                         ("callback", "refresh", "modal:action:open-location", 15001))
        data, observations, _ = self.data()
        observations["native"] = snapshot.merge_observations(rows)
        self.assertTrue(any(finding.startswith("safety:") for finding in
                            snapshot.check(data, observations, set(), updating=True)))

    def test_native_lifecycle_create_callbacks_require_coverage(self):
        audit = snapshot._module("audit_scheduler_creates", snapshot.ROOT / "tools/audit-scheduler.py")
        for flag, required in (("sharedFlightLoad", 2), ("flightOwnerHandoff", 2), ("flightModelSwitch", 3)):
            with self.subTest(flag=flag):
                stats = {"callback:create": {"n": 1}, "callback:create@load": {"n": required - 1}}
                audit.check_create_coverage("lifecycle", {flag: True}, stats)
                stats["callback:create@load"]["n"] -= 1
                with self.assertRaisesRegex(RuntimeError, "missing separately measured create callbacks"):
                    audit.check_create_coverage("lifecycle", {flag: True}, stats)
        bucket = dict(n=1, min=500, max=15001, selfMin=100, selfMax=200)
        rows = snapshot.native_rows("shared", {"stats": {
            "callback:create@load": {"units": {"1": bucket}},
        }})
        self.assertEqual((rows[0]["kind"], rows[0]["name"], rows[0]["stage"], rows[0]["max"]),
                         ("callback", "create", "shared:load:", 15001))

    def test_atomic_write_and_radio_safe_roundtrip(self):
        data, _, _ = self.data()
        data["record"]["provenance"] = {'quoted"key': "first\nsecond"}
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "snapshot.lua"
            path.write_text("original")
            sha = hashlib.sha256(path.read_bytes()).hexdigest()
            snapshot.write(**data, path=path, expected_sha=sha)
            self.assertEqual(snapshot.load(path), data)
            before = path.read_bytes()
            with self.assertRaises(RuntimeError):
                snapshot.write(**data, path=path, expected_sha=sha)
            self.assertEqual(path.read_bytes(), before)
            self.assertEqual(len(list(Path(directory).iterdir())), 1)
            data["record"]["overflow"] = 2147483648
            with self.assertRaises(ValueError):
                snapshot.render(**data)
            self.assertEqual(path.read_bytes(), before)


if __name__ == "__main__":
    unittest.main()

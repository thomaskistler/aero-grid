# SPDX-License-Identifier: GPL-2.0-only
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

from capture_recipes import PANELS
import scheduler_audit as audit


def load_cli():
    spec = importlib.util.spec_from_file_location("audit_scheduler", Path(__file__).with_name("audit-scheduler.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class InstrumentationTests(unittest.TestCase):
    def test_framework_measures_uninstrumented_chart_and_packages_shared_fixture(self):
        cli = load_cli()
        with tempfile.TemporaryDirectory() as directory:
            sd = Path(directory)
            widget = sd / "WIDGETS/AeroGrid"
            (widget / "panels").mkdir(parents=True)
            (widget / "audit").mkdir()
            (widget / "panels/chart.lua").write_text("instrumented chart")
            with mock.patch.object(cli, "prepare"):
                cli.prepare_framework(None, sd, [audit.CASE_DIR / "chart-frame.lua"])
            self.assertEqual((widget / "panels/chart.lua").read_text(),
                             (audit.WIDGET / "panels/chart.lua").read_text())
            self.assertEqual((widget / "audit/scheduler_chart_fixture.lua").read_text(),
                             (audit.SUPPORT_DIR / "scheduler_chart_fixture.lua").read_text())
            self.assertEqual((widget / "audit/memory_files.lua").read_text(),
                             (audit.SUPPORT_DIR / "memory_files.lua").read_text())

    def test_patches_still_match_the_shipped_sources(self):
        # A refactor that moves an instrumented call site must update the audit.
        for relative, patch in (("main.lua", audit.patch_main), ("lib/dashboard_loader.lua", audit.patch_loader),
                                ("panels/chart.lua", audit.patch_chart)):
            patched = patch((audit.WIDGET / relative).read_text())
            self.assertNotEqual(patched, (audit.WIDGET / relative).read_text(), relative)

    def test_the_host_mode_is_patched_for_new_mode(self):
        source = (audit.WIDGET / "main.lua").read_text()
        self.assertEqual(audit.patch_mode(source, "mixed"), source)
        self.assertIn('local SCHEDULER_MODE = "new"', audit.patch_mode(source, "new"))
        self.assertIn('local SCHEDULER_MODE = "legacy"', audit.patch_mode(source, "legacy"))

    def test_flight_adapter_fixture_keeps_production_activation_isolated(self):
        source = (audit.WIDGET / "main.lua").read_text()
        changed = audit.patch_flight_tasks(source)
        self.assertIn("owner:enableScheduler(context)", changed)
        self.assertNotIn("owner:enableScheduler(context)", source)
        self.assertIn('if scheduling and not owner.schedulerEnabled then\n        scheduling:charge("tick")', changed)
        self.assertIn("not context.stage and not context.reloadState", changed)
        with self.assertRaises(RuntimeError):
            audit.patch_flight_tasks(source.replace("    local now = getTime()\n", ""))

    def test_owner_overrides_only_patch_named_legacy_owners(self):
        source = (audit.WIDGET / "lib/scheduler_host.lua").read_text()
        self.assertEqual(audit.patch_owners(source, []), source)
        changed = audit.patch_owners(source, ["panel:metric"])
        self.assertIn('["panel:metric"] = "new"', changed)
        self.assertIn('["service:flight"] = "legacy"', changed)
        with self.assertRaises(RuntimeError):
            audit.patch_owners(source, ["panel:not-installed"])
        with self.assertRaises(ValueError):
            audit.patch_owners(source, ['panel:metric"'])

    def test_a_missing_anchor_is_reported(self):
        with self.assertRaisesRegex(RuntimeError, "expected one occurrence"):
            audit.patch_main("return {}")

    def test_probe_files_compile(self):
        try:
            import lupa
        except ImportError:
            self.skipTest("lupa is not installed")
        runtime = lupa.LuaRuntime()
        compile_source = runtime.eval("function(source) return load(source) end")
        sources = [audit.PROBE_DIR / "probe.lua", audit.PROBE_DIR / "inputs.lua",
                   audit.PROBE_DIR / "framework.lua", audit.PROBE_DIR / "framework-main.lua",
                   audit.SUPPORT_DIR / "scheduler_overhead.lua", audit.SUPPORT_DIR / "scheduler_measure.lua",
                   audit.SUPPORT_DIR / "scheduler_mixes.lua"]
        sources += [audit.patch_main((audit.WIDGET / "main.lua").read_text())]
        sources += [audit.patch_flight_tasks((audit.WIDGET / "main.lua").read_text())]
        sources += [audit.patch_chart((audit.WIDGET / "panels/chart.lua").read_text())]
        for source in sources:
            text = source.read_text() if isinstance(source, Path) else source
            result = compile_source(text)
            self.assertNotIsInstance(result, tuple, result)

    def test_link_toggle_removes_all_receiver_evidence_and_recovers(self):
        from lupa.lua53 import LuaRuntime
        runtime = LuaRuntime(unpack_returned_tuples=True)
        runtime.execute("""
            NOW = 0
            config = { toggleLink = true, swing = 0 }
            function getTime() return NOW end
            function getValue() return 42 end
            function getRSSI() return 72 end
            function getSourceValue() return 42, true, true end
            function loadScript() return function() return config end end
        """)
        env = runtime.execute((audit.PROBE_DIR / "inputs.lua").read_text())
        self.assertEqual(env.getValue("RQly"), 42)
        self.assertEqual(env.getRSSI(), 72)
        runtime.globals().NOW = 400
        self.assertEqual(env.getValue("RQly"), 0)
        self.assertEqual(env.getRSSI(), 0)
        self.assertEqual(env.getSourceValue(1), (0, True, False))
        runtime.globals().NOW = 800
        self.assertEqual(env.getValue("RQly"), 42)
        self.assertEqual(env.getRSSI(), 72)
        self.assertEqual(env.getSourceValue(1), (42, True, True))
        runtime.globals().config.toggleLink = False
        runtime.globals().NOW = 1200
        self.assertEqual(env.getSourceValue(1), (42, True, True))


class ScenarioTests(unittest.TestCase):
    def setUp(self):
        self.cli = load_cli()

    def test_flight_adapters_cover_shared_demand_without_a_counter(self):
        scenarios = self.cli.scenarios()
        for name in ("flight-smart-tasks", "flight-smart-tasks-no-counter"):
            self.assertTrue(scenarios[name]["flightTasks"])
            self.assertEqual(scenarios[name]["owners"], ["service:flight", "service:smart"])
        self.assertNotIn("type: flight-counter", scenarios["flight-smart-tasks-no-counter"]["layout"])
        self.assertNotIn("flightTasks", scenarios["flight-smart"])
        with self.assertRaisesRegex(ValueError, "require --mode mixed"):
            self.cli.prepare(None, "flight-smart-tasks", scenarios["flight-smart-tasks"], Path("unused"))

    def test_probe_tasks_cover_each_service_and_keep_owner_override_isolated(self):
        scenarios = self.cli.scenarios()
        for service in ("telemetry", "model", "control", "navigation"):
            for tag in ("min", "max", "4"):
                case = scenarios[f"service-probe-tasks-{service}-{tag}"]
                self.assertEqual(case["owners"], ["panel:service-probe"])
                self.assertEqual(case["config"]["service"], service)
                self.assertEqual(case["expected"], 4 if tag == "4" else 1)

    def test_diagnostics_tasks_cover_each_report_and_seed_real_log_and_sources(self):
        scenarios = self.cli.scenarios()
        for section in ("identity", "theme", "panels", "sources", "log"):
            for tag in ("min", "max", "4"):
                case = scenarios[f"host-diagnostics-tasks-{section}-{tag}"]
                self.assertEqual(case["owners"], ["panel:host-diagnostics"])
                self.assertEqual(case["config"]["section"], section)
                self.assertEqual(case["expected"], 4 if tag == "4" else 1)
                self.assertEqual(case["logEntries"], 256 if section == "log" else 0)
                self.assertEqual(case["diagnosticsSources"], 8 if section == "sources" else 0)

    def test_idle_showcase_ownership_is_isolated(self):
        case = self.cli.scenarios()["theme-showcase-tasks"]
        self.assertEqual(case["owners"], ["panel:theme-showcase"])
        self.assertEqual(case["expected"], 1)

    def test_every_panel_is_audited_at_its_smallest_and_largest_span(self):
        scenarios = self.cli.scenarios()
        for panel in PANELS:
            small, large = audit.supported_spans(panel)
            self.assertLessEqual(small[0] * small[1], large[0] * large[1])
            for tag in ("min", "max"):
                self.assertIn(f"{panel}-{tag}", scenarios)

    def test_the_model_panels_scenario_reads_every_model_facet(self):
        spec = self.cli.scenarios()["model-panels"]
        self.assertEqual(spec["expected"], 4)
        for panel in ("model-identity", "flight-mode", "flight-timer", "tx-battery"):
            self.assertIn(f"type: {panel}", spec["layout"])

    def test_editor_scenarios_require_native_fullscreen_and_completed_preview(self):
        scenarios = self.cli.scenarios()
        for name, count in (("editor-preview-metric", 16), ("editor-preview-chart", 1)):
            spec = scenarios[name]
            self.assertTrue(spec["fullscreen"])
            self.assertEqual(spec["expected"], count)
            self.assertEqual([phase["action"] for phase in spec["phases"] if "action" in phase],
                             ["open-editor", "check-editor", "select-editor", "check-render", "close-editor"])

    def test_modal_recording_case_keeps_real_chart_and_log_demand(self):
        spec = self.cli.scenarios()["modal-log-recording"]
        self.assertTrue(spec["fullscreen"])
        self.assertTrue(spec["settings"])
        self.assertEqual(spec["expected"], 2)
        self.assertEqual(spec["sources"], 1)
        self.assertIn("type: chart", spec["layout"])
        self.assertIn("type: host-diagnostics", spec["layout"])
        self.assertIn("section: log", spec["layout"])

    def test_editor_task_owners_do_not_change_legacy_preview_cases(self):
        scenarios = self.cli.scenarios()
        for panel in ("metric", "chart"):
            name = f"editor-preview-{panel}"
            self.assertNotIn("owners", scenarios[name])
            self.assertEqual(scenarios[name + "-tasks"]["owners"], [f"panel:{panel}"])
            self.assertEqual(scenarios[name + "-tasks"]["phases"], scenarios[name]["phases"])

    def test_drawer_scenarios_require_completed_root_and_nested_construction(self):
        scenarios = self.cli.scenarios()
        for panel in PANELS:
            spec = scenarios[f"editor-drawer-{panel}"]
            self.assertTrue(spec["fullscreen"])
            self.assertEqual(spec["expected"], 1)
            self.assertNotIn("owners", spec)
            self.assertEqual([phase["action"] for phase in spec["phases"] if "action" in phase],
                             ["open-editor", "open-drawer", "check-drawer", "close-editor"])
        for panel in ("metric", "chart", "state"):
            spec = scenarios[f"editor-entry-{panel}"]
            self.assertEqual([phase["action"] for phase in spec["phases"] if "action" in phase],
                             ["open-editor", "open-drawer", "check-drawer",
                              "open-entry-drawer", "check-drawer", "close-editor"])
        actions = [phase["action"] for phase in scenarios["editor-state-detail"]["phases"] if "action" in phase]
        self.assertEqual(actions.count("open-entry-drawer"), 2)
        self.assertEqual(actions.count("check-drawer"), 3)

    def test_settings_reset_case_keeps_rich_dashboard_and_logical_picker_extremes(self):
        spec = self.cli.scenarios()["modal-settings-reset"]
        self.assertEqual(spec["expected"], 7)
        self.assertTrue(spec["settings"])
        self.assertTrue(spec["fullscreen"])
        self.assertNotIn("owners", spec)
        for value in ("armed: L64", "sessionReset: L03", "motorSource: ch32", "flightSwitch: L64"):
            self.assertIn(value, spec["settingsDocument"])
        self.assertEqual(spec["layout"].count("  - id:"), 7)
        saved = self.cli.scenarios()["modal-settings-save"]
        self.assertIn('flightSwitch: ""', saved["settingsDocument"])
        actions = [phase["action"] for phase in saved["phases"] if "action" in phase]
        self.assertEqual(actions[-3:], ["edit-settings", "check-settings-save", "close-settings"])
        self.assertIn("flightSwitch: L63", self.cli.scenarios()["modal-settings-save-output"]["settingsDocument"])
        variants = self.cli.scenarios()
        self.assertEqual(variants["modal-settings-publication-background"]["phases"][3]["kind"], "background")
        self.assertEqual(variants["modal-settings-publication-error"]["expectedError"],
                         "Model settings: injected save failure")
        self.assertEqual(variants["modal-settings-publication-replaced"]["expectedError"],
                         "Model settings: Model settings publication was replaced")
        self.assertEqual(variants["modal-settings-close-return"]["phases"][-1]["event"], "EVT_VIRTUAL_EXIT")

    def test_run_requires_measured_actions_and_requests_native_fullscreen(self):
        spec = {"phases": [{"action": "open-editor"}], "fullscreen": True}
        for measured in (False, True):
            with self.subTest(measured=measured), tempfile.TemporaryDirectory() as directory:
                def native(command, **kwargs):
                    sd = Path(command[2])
                    sd.mkdir()
                    data = {"stats": {"callback:action:open-editor": {"n": 1}}} if measured else {}
                    (sd / "audit-results.json").write_text(json.dumps(data))
                    return mock.Mock(returncode=0)

                with mock.patch.object(self.cli, "OUTPUT", Path(directory)), \
                        mock.patch.object(self.cli, "prepare"), \
                        mock.patch.object(self.cli.subprocess, "run", side_effect=native) as run:
                    if measured:
                        self.cli.run(None, Path("native"), Path("library"), "editor", spec, 30)
                    else:
                        with self.assertRaisesRegex(RuntimeError, "missing timed action"):
                            self.cli.run(None, Path("native"), Path("library"), "editor", spec, 30)
                    self.assertIn("fullscreen", run.call_args.args[0])

    def test_preview_rebuild_scenarios_verify_changed_settings_and_discard(self):
        scenarios = self.cli.scenarios()
        for panel in ("navigation", "metric", "chart"):
            spec = scenarios[f"editor-rebuild-{panel}"]
            self.assertTrue(spec["fullscreen"])
            self.assertEqual(spec["expected"], 1)
            self.assertEqual([phase["action"] for phase in spec["phases"] if "action" in phase],
                             ["open-editor", "edit-preview", "check-preview", "discard-editor"])
        tape = scenarios["editor-rebuild-navigation-tape"]
        self.assertFalse(tape["config"]["showTape"])
        self.assertEqual(tape["phases"], scenarios["editor-rebuild-navigation"]["phases"])

    def test_every_scenario_names_its_expected_panels(self):
        for name, spec in self.cli.scenarios().items():
            self.assertIn("expected", spec, name)
            self.assertTrue(spec["phases"] or "loops" in spec, name)

    def test_metric_task_scenarios_override_only_the_metric_owner(self):
        for tag in ("min", "max", "16"):
            spec = self.cli.scenarios()[f"metric-tasks-{tag}"]
            self.assertEqual(spec["owners"], ["panel:metric"])
            self.assertEqual([phase["name"] for phase in spec["phases"]], ["refresh", "background"])

    def test_reset_tasks_use_the_real_reset_stimulus_with_isolated_panel_owners(self):
        scenarios = self.cli.scenarios()
        spec = scenarios["session-reset-tasks"]
        self.assertTrue(spec["reset"])
        self.assertEqual(spec["owners"], ["panel:chart", "panel:metric"])
        self.assertEqual(spec["layout"], scenarios["session-reset"]["layout"])
        self.assertEqual(spec["phases"], scenarios["session-reset"]["phases"])

    def test_link_task_scenarios_cover_elrs_and_generic_with_isolated_ownership(self):
        scenarios = self.cli.scenarios()
        for tag in ("min", "max", "16", "generic"):
            spec = scenarios[f"link-status-tasks-{tag}"]
            self.assertEqual(spec["owners"], ["panel:link-status"])
            self.assertEqual(spec["config"]["protocol"], "generic" if tag == "generic" else "elrs4")
            self.assertEqual(spec["config"]["visual"], "bar")
            self.assertTrue(spec["toggleLink"])
            self.assertEqual(spec["expected"], 16 if tag == "16" else 1)

    def test_navigation_task_scenarios_cover_visible_tapes_and_bearing(self):
        scenarios = self.cli.scenarios()
        for tag in ("min", "max", "16", "4", "bearing"):
            spec = scenarios[f"navigation-tasks-{tag}"]
            self.assertEqual(spec["owners"], ["panel:navigation"])
            self.assertEqual(spec["recipe"], "navigation")
            self.assertEqual(spec["config"]["showTape"], tag != "bearing")
        self.assertEqual(scenarios["navigation-tasks-4"]["expected"], 4)
        self.assertTrue(all(span[2:] == (2, 2) for span in scenarios["navigation-tasks-4"]["placements"].values()))

    def test_single_stage_panels_override_only_their_own_panel_owner(self):
        scenarios = self.cli.scenarios()
        for panel in ("flight-counter", "flight-mode", "flight-timer", "state", "trim-panel", "tx-battery", "model-identity"):
            for tag in ("min", "max", "16"):
                spec = scenarios[f"{panel}-tasks-{tag}"]
                self.assertEqual(spec["owners"], [f"panel:{panel}"])
                self.assertEqual(spec["recipe"], panel)
                self.assertEqual(spec["expected"], 16 if tag == "16" else 1)
                self.assertEqual([phase["name"] for phase in spec["phases"]], ["refresh", "background"])
                self.assertEqual(spec["toggleSwitches"], panel == "state")

    def test_control_panel_pair_overrides_both_panel_owners(self):
        spec = self.cli.scenarios()["control-panel-tasks"]
        self.assertEqual(spec["owners"], ["panel:state", "panel:trim-panel"])
        self.assertEqual(spec["expected"], 2)
        self.assertTrue(spec["toggleSwitches"])

    def test_rx_battery_tasks_measure_adaptive_supporting_rows(self):
        for tag in ("min", "max", "16"):
            spec = self.cli.scenarios()[f"rx-battery-tasks-{tag}"]
            self.assertEqual(spec["owners"], ["panel:rx-battery"])
            self.assertEqual(spec["expected"], 16 if tag == "16" else 1)
            self.assertEqual(spec["config"], {"visual": "bar", "showPack": True,
                                               "showCount": True, "showDelta": True})

    def test_lua_literal_round_trips_through_lua(self):
        try:
            import lupa
        except ImportError:
            self.skipTest("lupa is not installed")
        value = {"scenario": "x", "phases": [{"callbacks": 3, "trace": True}], "swing": 0.4}
        table = lupa.LuaRuntime().eval(audit.lua_literal(value))
        self.assertEqual(table["scenario"], "x")
        self.assertEqual(table["phases"][1]["callbacks"], 3)
        self.assertEqual(table["swing"], 0.4)

    def test_synthetic_inputs_describe_smart_sensors_only_when_asked(self):
        self.assertNotIn('name = "Alt"', self.cli.synthetic_inputs(3))
        self.assertIn('name = "Alt"', self.cli.synthetic_inputs(3, smart=True))


class ReductionTests(unittest.TestCase):
    def test_reduce_results_reports_the_worst_cost_per_unit(self):
        results = {"stats": {"service:telemetry": {
            "n": 3, "mean": 100.0, "min": 40, "max": 200, "selfMax": 20,
            "units": {"1": {"n": 1, "max": 60, "selfMax": 10}, "4": {"n": 2, "max": 200, "selfMax": 20}},
        }}}
        row = audit.reduce_results(results)["service:telemetry"]
        self.assertEqual(row["maxUnits"], 4)
        self.assertEqual(row["maxAtMaxUnits"], 200)
        self.assertEqual(row["perUnit"], 60.0)

    def test_verify_hook_accepts_agreement_and_flags_drift(self):
        exact = {"counts": [10, 810, 1610]}
        self.assertEqual(audit.verify_hook(exact, {"usages": [0, 0, 4]}), [])
        self.assertEqual(len(audit.verify_hook(exact, {"usages": [0, 0, 9]})), 1)


class FrameworkReportTests(unittest.TestCase):
    def data(self, measured=450, level="high"):
        row = {"name": "run 4 (32 tasks)", "tasks": 32, "measured": measured, "charged": 500, "examined": 4,
               "ran": 4, "slack": 500 - measured}
        findings = [{"stage": "run", "grant": 1, "level": level, "ratio": 0.95}]
        return {
            "charges": {"fixed": 100, "examine": 48, "run": 160},
            "verdict": {"ok": measured <= 500, "failures": [row] if measured > 500 else [], "fixed": 90,
                        "examine": 35.0, "perRun": 187.0, "slack": row["slack"], "tightest": row,
                        "headroom": 1.1, "tightestRatio": row},
            "overhead": {"rows": [row], "heap": {"kib": 12.5, "tasks": 128}},
            "cases": {"stub": {"worst": {"run": {"1": 100}}, "proposed": {"run": {"perUnit": 130}},
                               "findings": findings}},
        }

    def test_report_is_ok_when_every_callback_is_within_its_charge(self):
        ok, lines = audit.framework_report(self.data())
        self.assertTrue(ok)
        text = "\n".join(lines)
        self.assertIn("OK: every measured callback", text)
        self.assertIn("stub.run grant 1: high", text)

    def test_report_fails_over_the_charge_or_over_a_declared_bound(self):
        ok, lines = audit.framework_report(self.data(measured=501))
        self.assertFalse(ok)
        self.assertIn("FAIL", "\n".join(lines))
        self.assertFalse(audit.framework_report(self.data(level="exceeds"))[0])

    def test_report_fails_when_a_release_costs_more_than_the_planner_charged(self):
        data = self.data()
        data["cases"]["stub"]["planner"] = {"measured": 250, "charged": 420}
        ok, lines = audit.framework_report(data)
        self.assertTrue(ok)
        self.assertIn("stub: framework cost of one release 250, charged 420", "\n".join(lines))
        data["cases"]["stub"]["planner"]["measured"] = 421
        self.assertFalse(audit.framework_report(data)[0])

    def test_grants_one_to_n_arrive_as_an_array_from_the_native_encoder(self):
        data = self.data()
        data["cases"]["stub"]["worst"] = {"run": [100, 190, 280]}
        self.assertIn("stub.run: worst per grant 1=100 2=190 3=280", "\n".join(audit.framework_report(data)[1]))

    def test_framework_image_runs_the_measurements_only(self):
        capture = load_cli().capture_module()
        cases = sorted(audit.CASE_DIR.glob("*.lua"))
        self.assertTrue(cases)
        with tempfile.TemporaryDirectory() as directory:
            sd = Path(directory) / "sd"
            load_cli().prepare_framework(capture, sd, cases)
            widget = sd / "WIDGETS/AeroGrid"
            self.assertEqual((widget / "main.lua").read_text(), (audit.PROBE_DIR / "framework-main.lua").read_text())
            self.assertTrue((widget / "lib/scheduler.lua").is_file())
            for name in ("framework.lua", "scheduler_overhead.lua", "scheduler_measure.lua", "scheduler_mixes.lua",
                         "scheduler_flight_readout.lua", "scheduler_probe_fixture.lua",
                         "scheduler_diagnostics_fixture.lua", "cases/stub.lua", "cases/telemetry.lua",
                         "cases/service-probe-panel.lua", "cases/host-diagnostics-panel.lua"):
                self.assertTrue((widget / "audit" / name).is_file(), name)
            self.assertIn('"stub"', (widget / "audit/config.lua").read_text())


class HookCheckTests(unittest.TestCase):
    def report(self, firmware_usages):
        cli = load_cli()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name, body in (("hook-check", {"counts": [10, 810, 1610]}),
                               ("hook-check-firmware", {"usages": firmware_usages})):
                (root / name).mkdir()
                (root / name / "results.json").write_text(json.dumps(body))
            stderr = io.StringIO()
            with mock.patch.object(cli, "OUTPUT", root), mock.patch.object(sys, "argv", ["audit", "--report"]), \
                    contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(stderr):
                status = cli.main()
        return status, stderr.getvalue()

    def test_report_leaves_out_mixed_runs(self):
        cli = load_cli()

        def results(maximum):
            bucket = {"n": 1, "max": maximum, "selfMax": maximum}
            return {"stats": {"service:model": {"n": 1, "mean": maximum, "min": maximum, "max": maximum,
                                                "selfMax": maximum, "units": {"1": bucket}}}}

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name, maximum in (("scenario", 220), ("scenario-mixed", 999)):
                (root / name).mkdir()
                (root / name / "results.json").write_text(json.dumps(results(maximum)))
            out = io.StringIO()
            with mock.patch.object(cli, "OUTPUT", root), mock.patch.object(sys, "argv", ["audit", "--report"]), \
                    contextlib.redirect_stdout(out):
                cli.main()
        self.assertIn("service:model\t1\t220", out.getvalue())
        self.assertNotIn("999", out.getvalue())

    def test_status_reports_agreement_and_mismatch(self):
        self.assertTrue(audit.hook_check_status({"counts": [10, 810]}, {"usages": [0, 0]})[0])
        ok, message = audit.hook_check_status({"counts": [10, 810]}, {"usages": [0, 9]})
        self.assertFalse(ok)
        self.assertIn("MISMATCH", message)

    def test_report_exits_nonzero_when_the_counter_disagrees_with_the_firmware(self):
        status, errors = self.report([0, 0, 9])
        self.assertEqual(status, 1)
        self.assertIn("MISMATCH", errors)

    def test_report_exits_zero_when_they_agree(self):
        self.assertEqual(self.report([0, 0, 4]), (0, ""))


if __name__ == "__main__":
    unittest.main()

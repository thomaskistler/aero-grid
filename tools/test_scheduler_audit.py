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
    def test_patches_still_match_the_shipped_sources(self):
        # A refactor that moves an instrumented call site must update the audit.
        for relative, patch in (("main.lua", audit.patch_main), ("lib/dashboard_loader.lua", audit.patch_loader),
                                ("panels/chart.lua", audit.patch_chart)):
            patched = patch((audit.WIDGET / relative).read_text())
            self.assertNotEqual(patched, (audit.WIDGET / relative).read_text(), relative)

    def test_the_host_mode_is_patched_only_when_asked(self):
        source = (audit.WIDGET / "main.lua").read_text()
        self.assertEqual(audit.patch_mode(source, "legacy"), source)
        self.assertIn('local SCHEDULER_MODE = "mixed"', audit.patch_mode(source, "mixed"))

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
        sources += [audit.patch_chart((audit.WIDGET / "panels/chart.lua").read_text())]
        for source in sources:
            text = source.read_text() if isinstance(source, Path) else source
            result = compile_source(text)
            self.assertNotIsInstance(result, tuple, result)


class ScenarioTests(unittest.TestCase):
    def setUp(self):
        self.cli = load_cli()

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

    def test_every_scenario_names_its_expected_panels(self):
        for name, spec in self.cli.scenarios().items():
            self.assertIn("expected", spec, name)
            self.assertTrue(spec["phases"] or "loops" in spec, name)

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
                         "cases/stub.lua"):
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

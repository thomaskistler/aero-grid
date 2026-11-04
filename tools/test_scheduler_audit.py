# SPDX-License-Identifier: GPL-2.0-only
import importlib.util
from pathlib import Path
import unittest

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
        sources = [audit.PROBE_DIR / "probe.lua", audit.PROBE_DIR / "inputs.lua"]
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


if __name__ == "__main__":
    unittest.main()

# SPDX-License-Identifier: GPL-2.0-only

import importlib.util
from pathlib import Path
import sys
import unittest

EXPERIMENTS = Path(__file__).resolve().parent / "experiments"
sys.path.insert(0, str(EXPERIMENTS))
SPEC = importlib.util.spec_from_file_location("runtime_gate", EXPERIMENTS / "run_chart_runtime_gate.py")
GATE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GATE)
sys.path.pop(0)


class RuntimeGateTests(unittest.TestCase):
    def test_long_flight_requires_explicit_complete_coverage(self):
        report = {}
        self.assertFalse(GATE.coverage_passes(report, "long-flight"))
        report["coverage"] = [{
            "levels": "11", "scrolls_per_series": "6", "logical_step": "50",
            "admission_ms": "50", "uninterrupted": "1", "retired_levels_per_series": "10",
        }]
        self.assertTrue(GATE.coverage_passes(report, "long-flight"))
        for field in ("levels", "scrolls_per_series", "uninterrupted", "retired_levels_per_series"):
            original = report["coverage"][0][field]
            report["coverage"][0][field] = "0"
            self.assertFalse(GATE.coverage_passes(report, "long-flight"))
            report["coverage"][0][field] = original

    def test_extended_cases_and_fixture_settings(self):
        cases = GATE.cases(extended=True)
        self.assertEqual(len(cases), 15)
        self.assertEqual(len(GATE.cases()), 7)
        self.assertEqual(len({name for name, _, _ in cases}), len(cases))
        driver = (EXPERIMENTS / "native_chart_mipmap_operations.lua").read_text(encoding="ascii")
        source = GATE.controlled_source(driver, "scroll", {"scrollLap": 4.25, "widthReduction": 172})
        self.assertIn('local operation = "scroll"', source)
        self.assertIn("local scrollLap = 4.25", source)
        self.assertIn("local widthReduction = 172", source)
        with self.assertRaises(ValueError):
            GATE.controlled_source("", "scroll", {"scrollLap": 4.25})

    def report(self):
        return {
            "workload_completed": True,
            "callback_trace_complete": True,
            "callback_samples": [73],
            "paint": {"verified": True, "mismatched_pixels": 0, "paint_complete_ms": 900},
        }

    def test_strict_instruction_limit(self):
        report = self.report()
        self.assertTrue(GATE.report_passes(report, painted=True))
        report["callback_samples"] = [74]
        self.assertFalse(GATE.report_passes(report, painted=True))

    def test_rebuilt_cases_require_explicit_coverage(self):
        self.assertFalse(GATE.coverage_passes({}, "rolling"))
        self.assertFalse(GATE.coverage_passes({}, "late-attach"))
        self.assertTrue(GATE.coverage_passes({"coverage": [{
            "rolling": "1", "fixed_span": "6000", "scrolled": "1", "sole_renderer": "1",
        }]}, "rolling"))
        report = {
            "coverage": [{
                "late_attach": "1", "rebuilt": "1", "retained_history": "1", "sole_renderer": "1",
            }],
            "phase_profile": {"rebuild": 508, "renderer_setup": 162},
            "late_attach": {
                "attach_to_publish_ms": 100000,
                "attach_to_publish_callbacks": 1400,
                "callbacks": 2000,
            },
        }
        self.assertTrue(GATE.coverage_passes(report, "late-attach"))
        report["late_attach"]["attach_to_publish_ms"] = 105000
        self.assertFalse(GATE.coverage_passes(report, "late-attach"))

    def test_incomplete_or_missing_callback_samples_fail(self):
        for field, value in (("workload_completed", False), ("callback_trace_complete", False),
                             ("callback_samples", [])):
            report = self.report()
            report[field] = value
            self.assertFalse(GATE.report_passes(report, painted=False))

    def test_painted_cases_require_verified_output(self):
        for field, value in (("verified", False), ("mismatched_pixels", 1), ("paint_complete_ms", None)):
            report = self.report()
            report["paint"][field] = value
            self.assertFalse(GATE.report_passes(report, painted=True))
            self.assertTrue(GATE.report_passes(report, painted=False))

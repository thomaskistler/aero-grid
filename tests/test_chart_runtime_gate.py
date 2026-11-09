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

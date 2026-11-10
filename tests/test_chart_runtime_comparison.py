# SPDX-License-Identifier: GPL-2.0-only

import importlib.util
from pathlib import Path
import sys
import unittest

EXPERIMENTS = Path(__file__).resolve().parent / "experiments"
sys.path.insert(0, str(EXPERIMENTS))
SPEC = importlib.util.spec_from_file_location("comparison", EXPERIMENTS / "run_chart_runtime_comparison.py")
COMPARISON = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(COMPARISON)
sys.path.pop(0)


class FrozenComparisonTests(unittest.TestCase):
    def report(self):
        return {
            "workload_completed": True,
            "measurements": [{
                "trace_version": "1", "op": "horizontal", "trigger": "6001",
                "seed_end": "5990", "seed_step": "11", "prefix_samples": "3276",
                "prefix_hash": "4097166", "prefix_break_hash": "123", "events": "24",
                "event_hash": "13624132", "event_break_hash": "456",
                "input_batches": "4", "period_ms": "50", "sources": "24", "columns": "398,398",
                "callbacks": "50", "started_ms": "1000", "submitted_ms": "3000",
            }],
            "callback_trace_complete": True,
            "callback_samples": [78],
            "paint": {"verified": True, "mismatched_pixels": 0, "paint_complete_ms": 2000},
        }

    def test_identical_inputs_allow_different_completion_times(self):
        first, second = self.report(), self.report()
        second["measurements"][0].update(callbacks="60", started_ms="5000", submitted_ms="8000")
        second["paint"]["paint_complete_ms"] = 3000
        signature = COMPARISON.compare([first, second])
        self.assertEqual(signature["prefix_hash"], "4097166")
        self.assertEqual(signature["event_hash"], "13624132")
        self.assertTrue(COMPARISON.native_checks_pass(second))

    def test_every_input_mismatch_rejects_comparison(self):
        for field in COMPARISON.INPUT_FIELDS:
            with self.subTest(field=field):
                second = self.report()
                second["measurements"][0][field] = "different"
                with self.assertRaises(ValueError):
                    COMPARISON.compare([self.report(), second])

    def test_missing_fingerprints_and_incomplete_workloads_are_rejected(self):
        for field in COMPARISON.INPUT_FIELDS:
            second = self.report()
            del second["measurements"][0][field]
            with self.subTest(field=field), self.assertRaises(ValueError):
                COMPARISON.compare([self.report(), second])
        second = self.report()
        second["workload_completed"] = False
        with self.assertRaises(ValueError):
            COMPARISON.compare([self.report(), second])
        with self.assertRaises(ValueError):
            COMPARISON.compare([self.report()])

    def test_matching_inputs_do_not_override_budget_or_pixel_failures(self):
        for key, value in (("callback_trace_complete", False), ("callback_samples", []),
                           ("callback_samples", [79])):
            report = self.report()
            report[key] = value
            self.assertFalse(COMPARISON.native_checks_pass(report))
        for key, value in (("verified", False), ("mismatched_pixels", 1), ("paint_complete_ms", None)):
            report = self.report()
            report["paint"][key] = value
            self.assertFalse(COMPARISON.native_checks_pass(report))


if __name__ == "__main__":
    unittest.main()

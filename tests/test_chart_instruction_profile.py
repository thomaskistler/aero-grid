# SPDX-License-Identifier: GPL-2.0-only

import importlib.util
from pathlib import Path
import sys
import unittest

EXPERIMENTS = Path(__file__).resolve().parent / "experiments"
sys.path.insert(0, str(EXPERIMENTS))
SPEC = importlib.util.spec_from_file_location("instruction_profile", EXPERIMENTS / "profile_chart_instructions.py")
PROFILE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PROFILE)
sys.path.pop(0)


class InstructionProfileTests(unittest.TestCase):
    def test_operation_distributions_and_missing_categories(self):
        names = ("empty", "update", "position", "reveal", "hide", "activation_probe")
        lines = [
            f"OPERATION kind={name} calls=2 instructions=20 squares=208 minimum=8 maximum=12"
            for name in names
        ]
        result = PROFILE.summarize_operations("\n".join(lines))
        self.assertEqual(result["empty"]["average"], 10)
        self.assertEqual(result["empty"]["population_stddev"], 2)
        for text in ("\n".join(lines[:-1]), "\n".join(lines + lines[:1]),
                     "\n".join(lines).replace("instructions=20", "instructions=30"),
                     "\n".join(lines).replace("calls=2", "calls=0")):
            with self.subTest(text=text), self.assertRaises(ValueError):
                PROFILE.summarize_operations(text)

    def trace(self):
        return (
            "RECIPIENT id=telemetry\nRECIPIENT id=chart1\nRECIPIENT id=idle\n"
            "CALLBACK index=1 instructions=3000 counter=3201 firmware_percent=16 period=200 "
            "unused=1 stage=drawing probe=3\n"
            "TASK callback=1 id=telemetry instructions=1000 slots=4\n"
            "TASK callback=1 id=chart1 instructions=1500 slots=3\n"
            "CALLBACK index=2 instructions=2000 counter=2199 firmware_percent=10 period=200 "
            "unused=3 stage=drawing probe=3\n"
            "TASK callback=2 id=telemetry instructions=500 slots=2\n"
            "TASK callback=2 id=chart1 instructions=1000 slots=3\n"
        )

    def test_instruction_and_slot_totals_include_idle_recipients(self):
        result = PROFILE.summarize(self.trace())
        self.assertEqual(result["callbacks"], 2)
        self.assertEqual(result["callback_instructions"], 5000)
        self.assertEqual(result["unattributed_instructions"], 1000)
        self.assertEqual(result["unused_slots"], 4)
        telemetry = result["recipients"]["telemetry"]
        self.assertEqual(telemetry, {
            "calls": 2, "slots": 6, "instructions": 1500,
            "average": 750, "minimum": 500, "maximum": 1000,
        })
        self.assertEqual(result["recipients"]["idle"]["instructions"], 0)
        self.assertIsNone(result["recipients"]["idle"]["average"])
        self.assertEqual(result["counter_probe_min"], 3)
        self.assertEqual(result["counter_probe_max"], 3)
        slots = result["instructions_per_charged_slot"]["chart1"]
        self.assertAlmostEqual(slots["average"], (500 + 1000 / 3) / 2)
        self.assertAlmostEqual(slots["minimum"], 1000 / 3)
        self.assertEqual(slots["maximum"], 500)
        self.assertAlmostEqual(slots["slot_weighted_average"], 2500 / 6)
        self.assertNotIn("idle", result["instructions_per_charged_slot"])

    def test_firmware_hook_disagreement_fails(self):
        for before, after in (("firmware_percent=16", "firmware_percent=15"),
                              ("period=200", "period=100")):
            with self.subTest(after=after), self.assertRaisesRegex(ValueError, "firmware hook"):
                PROFILE.summarize(self.trace().replace(before, after))

    def test_chart_distributions_separate_grants_and_subspans(self):
        detail = (
            "CHART callback=1 id=chart1 instructions=1500 slots=3 grant=4 series=3 "
            "stage=drawing after=decoration projection=1100 preparation=0 rebuild=0 view=0\n"
            "CHART callback=2 id=chart1 instructions=1000 slots=3 grant=3 series=3 "
            "stage=drawing after=drawing projection=800 preparation=0 rebuild=0 view=0\n"
        )
        result = PROFILE.summarize(self.trace() + detail)
        self.assertEqual(len(result["chart_turns"]), 2)
        self.assertEqual(result["chart_subspans"]["projection/grant=4/series=3"]["maximum"], 1100)
        self.assertEqual(result["chart_fixed_remainder"]["drawing->decoration"]["average"], 400)
        self.assertEqual(result["chart_fixed_remainder"]["drawing->drawing"]["average"], 200)
        for before, after in (("projection=1100", "projection=1600"), ("grant=4", "grant=0"),
                              ("instructions=1500", "instructions=1501")):
            with self.subTest(after=after), self.assertRaises(ValueError):
                PROFILE.summarize(self.trace() + detail.replace(before, after))

    def test_startup_phases_and_callback_breakdown(self):
        result = PROFILE.summarize(self.trace().replace("stage=drawing", "stage=drawing phase=warming"))
        row = result["callback_breakdown"][0]
        self.assertEqual(row["phase"], "warming")
        self.assertEqual(row["residual"], 500)
        self.assertEqual(len(row["tasks"]), 2)

    def test_inclusive_functions_are_separate_from_self_counts(self):
        source = "function chart.render(context)\nend\n"
        text = (
            "FUNCTION callback=1 source=panels/chart.lua line=1 instructions=100\n"
            "INCLUSIVE callback=1 source=panels/chart.lua line=1 instructions=300\n"
            "FUNCTION callback=2 source==? line=1 instructions=200\n"
            "INCLUSIVE callback=3 source=panels/chart.lua line=1 instructions=400\n"
        )
        result = PROFILE.summarize_functions(text, 2, source)
        self.assertEqual(result["startup/function chart.render(context)"]["average"], 300)
        self.assertEqual(result["operation/function chart.render(context)"]["average"], 400)
        for invalid in (text + text, text.replace("line=1", "line=9"), text.replace("callback=1", "callback=0")):
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                PROFILE.summarize_functions(invalid, 2, source)

    def test_missing_duplicate_and_unknown_records_fail(self):
        for text in (
            "", self.trace().replace("index=2", "index=3"),
            self.trace() + "RECIPIENT id=idle\n",
            self.trace() + "CALLBACK index=1 instructions=0\n",
            self.trace().replace("callback=2 id=telemetry", "callback=3 id=telemetry"),
            self.trace().replace("id=chart1 instructions", "id=unknown instructions"),
            self.trace() + "UNKNOWN key=value\n",
        ):
            with self.subTest(text=text), self.assertRaises(ValueError):
                PROFILE.summarize(text)

    def test_negative_counts_overlaps_and_unbalanced_slots_fail(self):
        for before, after in (
            ("instructions=1500", "instructions=-1"),
            ("instructions=1500", "instructions=9999"),
            ("slots=4", "slots=9"),
            ("unused=1", "unused=2"),
            ("probe=3", "probe=-1"),
        ):
            with self.subTest(after=after), self.assertRaises(ValueError):
                PROFILE.summarize(self.trace().replace(before, after))


if __name__ == "__main__":
    unittest.main()

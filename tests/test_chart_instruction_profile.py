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

    def test_firmware_hook_disagreement_fails(self):
        for before, after in (("firmware_percent=16", "firmware_percent=15"),
                              ("period=200", "period=100")):
            with self.subTest(after=after), self.assertRaisesRegex(ValueError, "firmware hook"):
                PROFILE.summarize(self.trace().replace(before, after))

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

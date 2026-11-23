# SPDX-License-Identifier: GPL-2.0-only
import importlib.util
from pathlib import Path
import unittest

SPEC = importlib.util.spec_from_file_location(
    "measure_model_settings", Path(__file__).with_name("measure-model-settings.py"))
measure = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(measure)


class ModelMeasurementTests(unittest.TestCase):
    def samples(self, first="1 armed 1 9"):
        return "\n".join([first] + [
            f"{row} {key} 3 2" for row, key in enumerate(measure.ROWS[1:], 2)])

    def test_instruction_bucket_and_row_names(self):
        samples = measure.parse_samples(self.samples())
        self.assertEqual(len(samples), 12)
        self.assertEqual(samples[0], {
            "row": "armed", "slots": 1, "callback_percent": 9,
            "callback_instructions_below": 2000,
        })
        self.assertEqual(samples[-1]["row"], "finish")

    def test_grant_threshold(self):
        for slots in range(1, 9):
            with self.subTest(slots=slots):
                measure.parse_samples(self.samples(f"1 armed {slots} {slots * 10 - 1}"))
                with self.assertRaisesRegex(RuntimeError, "does not fit"):
                    measure.parse_samples(self.samples(f"1 armed {slots} {slots * 10}"))

    def test_rejects_missing_duplicate_and_invalid_measurements(self):
        for text in ("", "1 armed 1 0", self.samples("2 armed 1 0"), self.samples("1 armed 0 0"),
                     self.samples("1 armed 9 0"), self.samples("1 armed 1 -1"),
                     self.samples("1 armed 1 101"), self.samples("1 motorSource 1 0"),
                     self.samples() + "\n12 extra 1 0"):
            with self.subTest(text=text):
                with self.assertRaises(RuntimeError):
                    measure.parse_samples(text)

    def callbacks(self, percent=40):
        return (f"{percent} 8 " + ",".join(measure.ROWS[:8]) + "\n"
                "20 5 " + ",".join(measure.ROWS[8:]))

    def test_complete_callback_threshold_and_total_slots(self):
        samples = measure.parse_callbacks(self.callbacks(74))
        self.assertEqual(sum(sample["model_slots"] for sample in samples), 13)
        self.assertEqual(samples[0]["callback_instructions_below"], 15000)
        with self.assertRaisesRegex(RuntimeError, "15,000"):
            measure.parse_callbacks(self.callbacks(75))

    def test_rejects_incomplete_reordered_or_overbooked_callbacks(self):
        for text in ("", "10 1 armed", self.callbacks().replace("armed,motorSource", "motorSource,armed"),
                     self.callbacks().replace("40 8 ", "40 9 "),
                     "40 13 " + ",".join(measure.ROWS)):
            with self.subTest(text=text):
                with self.assertRaises(RuntimeError):
                    measure.parse_callbacks(text)


if __name__ == "__main__":
    unittest.main()

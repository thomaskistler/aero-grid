# SPDX-License-Identifier: GPL-2.0-only

import importlib.util
from pathlib import Path
import struct
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "chart_feasibility", ROOT / "tests/experiments/run_chart_feasibility.py"
)
RUNNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RUNNER)


class ChartPaintTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.output = Path(self.directory.name)
        self.sd = self.output / "sd"
        self.sd.mkdir()
        (self.sd / "paint-1.txt").write_text(
            "1 10 100\nP 10 20 3 3 558268416\nL 11 21 2 1992196096\n"
        )

    def frame(self, stamp, missing_background=False):
        pixels = [0] * (480 * 272)
        for y in range(20, 23):
            for x in range(10, 13):
                pixels[y * 480 + x] = 0x2146
        for y in (21, 22):
            pixels[y * 480 + 11] = 0x76BE
        if missing_background:
            pixels[20 * 480 + 10] = 0
        return struct.pack("<II", 1, stamp) + struct.pack("<130560H", *pixels)

    def verify(self, *frames):
        (self.output / "frame.rgb565.trace").write_bytes(b"".join(frames))
        return RUNNER.verify_paint(self.output, self.sd)[0]

    def test_first_complete_frame_after_submission_uses_rgb565_upper_word(self):
        result = self.verify(self.frame(90), self.frame(100, True), self.frame(120))
        self.assertTrue(result["verified"])
        self.assertEqual(result["pixels_checked"], 9)
        self.assertEqual(result["mismatched_pixels"], 0)
        self.assertEqual(result["paint_complete_ms"], 110)
        self.assertEqual(result["paint_after_submission_ms"], 20)

    def test_a_stale_background_pixel_fails_the_complete_plot_comparison(self):
        result = self.verify(self.frame(90), self.frame(110, True))
        self.assertFalse(result["verified"])
        self.assertIsNone(result["paint_complete_ms"])
        self.assertEqual(result["mismatched_pixels"], 1)
        self.assertEqual(result["mismatch_examples"][0]["x"], 10)

    def test_truncated_capture_is_an_explicit_failure(self):
        for data in (b"\x00", self.frame(110)[:-1]):
            with self.subTest(size=len(data)), self.assertRaisesRegex(RuntimeError, "Truncated"):
                self.verify(data)


class ChartRuntimeLimitsTests(unittest.TestCase):
    def test_physical_resize_is_diagnostic_not_a_runtime_deadline(self):
        for operation in ("resize", "resized_scroll"):
            self.assertTrue(RUNNER.operation_limits(operation, 2000, 20, stress=True))
            self.assertFalse(RUNNER.operation_limits(operation, 2000, 20))

    def test_runtime_rescaling_keeps_its_deadline_and_turn_limits(self):
        for operation in ("horizontal", "vertical"):
            self.assertTrue(RUNNER.operation_limits(operation, 1000, 5, stress=True))
            self.assertFalse(RUNNER.operation_limits(operation, 1001, 5, stress=True))
            self.assertFalse(RUNNER.operation_limits(operation, 1000, 6, stress=True))
        self.assertTrue(RUNNER.operation_limits("scroll", 499, 2, stress=True))
        self.assertFalse(RUNNER.operation_limits("scroll", 500, 2, stress=True))


class MatchedPaintTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.output = Path(self.directory.name)
        self.text = ("MATCHED mode=integrated started_ms=100 submitted_ms=300\n"
                     "REGION 10 20 2 2\nREGION 30 40 2 2\n")
        self.reference = bytearray(480 * 272 * 2)
        struct.pack_into("<H", self.reference, (20 * 480 + 10) * 2, 0x1234)
        (self.output / "frame.rgb565").write_bytes(self.reference)

    def verify(self, frames):
        (self.output / "frame.rgb565.trace").write_bytes(b"".join(
            struct.pack("<II", phase, stamp) + data for phase, stamp, data in frames))
        return RUNNER.verify_matched_paint(self.output, self.text)

    def test_first_complete_paint_can_precede_submission_completion(self):
        result = self.verify([(1, 150, bytes(len(self.reference))),
                              (1, 200, self.reference), (2, 500, self.reference)])
        self.assertTrue(result["verified"])
        self.assertEqual(result["paint_complete_ms"], 100)
        self.assertEqual(result["submission_ms"], 200)
        self.assertEqual(result["pixels_checked"], 8)

    def test_missing_reference_phase_is_not_a_verified_paint(self):
        result = self.verify([(1, 200, self.reference)])
        self.assertFalse(result["verified"])
        self.assertFalse(result["reference_seen"])

    def test_stale_pixel_fails_the_whole_panel_comparison(self):
        result = self.verify([(1, 200, bytes(len(self.reference))), (2, 500, self.reference)])
        self.assertFalse(result["verified"])
        self.assertEqual(result["mismatched_pixels"], 1)

    def test_truncated_trace_is_an_explicit_failure(self):
        with self.assertRaisesRegex(RuntimeError, "Truncated matched"):
            self.verify([(1, 200, self.reference[:-1])])


if __name__ == "__main__":
    unittest.main()

# SPDX-License-Identifier: GPL-2.0-only

from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


RUNNER = Path(__file__).with_name("run.py")


class RunnerTests(unittest.TestCase):
    def run_suites(self, *sources):
        with tempfile.TemporaryDirectory() as directory:
            paths = []
            for index, source in enumerate(sources):
                path = Path(directory) / f"test_{index}.lua"
                path.write_text(source, encoding="ascii")
                paths.append(str(path))
            return subprocess.run(
                [
                    sys.executable,
                    "-c",
                    "import runpy, sys; from pathlib import Path; "
                    "run_test = runpy.run_path(sys.argv[1])['run_test']; "
                    "[run_test(Path(path)) for path in sys.argv[2:]]",
                    str(RUNNER),
                    *paths,
                ],
                capture_output=True,
                text=True,
            )

    def test_passing_negative_case_keeps_progress_but_not_error_logs(self):
        result = self.run_suites("""
            local originalPrint = print
            local logs = {}
            print = function(message) logs[#logs + 1] = message end
            print("[AeroGrid] ERROR captured by a test")
            assert(#logs == 1)
            print = originalPrint
            print("[AeroGrid] ERROR expected negative case")
            print("suite passed", 42)
            print("unrelated diagnostic")
        """)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "suite passed\t42\nunrelated diagnostic\n")
        self.assertEqual(result.stderr, "")

    def test_failure_replays_logs_and_preserves_traceback(self):
        result = self.run_suites("""
            print("[AeroGrid] ERROR first", 42, nil, false)
            print("[AeroGrid] ERROR second")
            print("progress before failure")
            assert(false, "deliberate assertion failure")
        """)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "progress before failure\n")
        self.assertIn("Failed Lua suite:", result.stderr)
        self.assertIn("test_0.lua", result.stderr)
        self.assertIn(
            "Captured AeroGrid logs:\n"
            "[AeroGrid] ERROR first\t42\tnil\tfalse\n"
            "[AeroGrid] ERROR second\n",
            result.stderr,
        )
        self.assertIn("Traceback (most recent call last)", result.stderr)
        self.assertIn("deliberate assertion failure", result.stderr)
        self.assertIn("stack traceback:", result.stderr)

    def test_failure_without_logs_still_fails(self):
        result = self.run_suites('error("plain runtime failure")')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Failed Lua suite:", result.stderr)
        self.assertIn("plain runtime failure", result.stderr)
        self.assertNotIn("Captured AeroGrid logs:", result.stderr)

    def test_logs_and_runtime_are_isolated_between_suites(self):
        result = self.run_suites(
            'leaked = true; print("[AeroGrid] ERROR passing suite only")',
            'assert(leaked == nil); error("second suite failed")',
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("second suite failed", result.stderr)
        self.assertNotIn("passing suite only", result.stdout + result.stderr)
        self.assertNotIn("Captured AeroGrid logs:", result.stderr)


if __name__ == "__main__":
    unittest.main()

# SPDX-License-Identifier: GPL-2.0-only
import importlib.util
from pathlib import Path
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "simulator_runner", ROOT / "tools/simulator-runner.py")
runner = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runner)


class SimulatorRunnerTests(unittest.TestCase):
    def test_parses_touch_and_key_actions_in_order(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "actions.txt"
            path.write_text(
                "# tick action\n0 touch 10 20 down\n10 touch 10 20 up\n"
                "15 wait drawer=none 20\n20 key 3 down\n"
            )
            self.assertEqual(
                runner.parse_actions(path, 100),
                [
                    {"tick": 0, "type": "touch", "x": 10, "y": 20, "state": "down"},
                    {"tick": 10, "type": "touch", "x": 10, "y": 20, "state": "up"},
                    {"tick": 15, "type": "wait", "token": "drawer=none", "timeout_ticks": 20},
                    {"tick": 20, "type": "key", "button": 3, "state": "down"},
                ],
            )

    def test_rejects_bad_order_and_out_of_bounds_inputs(self):
        invalid = (
            "1 touch 0 0 up\n0 touch 0 0 down\n",
            "0 touch 480 0 down\n",
            "0 key 256 down\n",
            "100 touch 0 0 down\n",
        )
        for source in invalid:
            with self.subTest(source=source), tempfile.TemporaryDirectory() as temporary:
                path = Path(temporary) / "actions.txt"
                path.write_text(source)
                with self.assertRaises(ValueError):
                    runner.parse_actions(path, 100)

    def test_detects_recorded_firmware_failure_messages(self):
        for text, expected in (
            ("ERROR in script", "firmware_error"),
            ("CPU limit exceeded", "instruction_limit"),
            ("Script killed by watchdog", "instruction_limit"),
            ("panic: test", "panic"),
            ("not enough memory", "lua_memory"),
            ("Lua shutdown", "lua_shutdown"),
            ("luaRef() failed", "lua_reference"),
        ):
            with self.subTest(text=text):
                self.assertIn(expected, runner.detect_log_signals(text))

    def test_does_not_treat_a_bare_luaref_mention_as_failure(self):
        self.assertNotIn("lua_reference", runner.detect_log_signals("luaRef() called"))

    def test_widget_heartbeat_cannot_substitute_for_action_postcondition(self):
        self.assertFalse(runner.progress_complete(True, False, True))
        self.assertFalse(runner.progress_complete(False, True, True))
        self.assertTrue(runner.progress_complete(True, True, True))

    def test_self_test_reports_parser_and_native_abort_verification_separately(self):
        result = runner.detector_self_test()
        self.assertTrue(result["overall_passed"])
        self.assertFalse(result["parser_tests_are_end_to_end"])
        self.assertTrue(result["cases"]["owned_process_abort"]["passed"])
        self.assertTrue(result["unverified_end_to_end"])

    def test_writes_png_for_native_framebuffer(self):
        with tempfile.TemporaryDirectory() as temporary:
            destination = Path(temporary) / "frame.png"
            runner.png_from_rgb565(bytes(480 * 272 * 2), destination)
            self.assertEqual(destination.read_bytes()[:8], b"\x89PNG\r\n\x1a\n")

    def test_progress_hook_is_test_only_and_records_refresh_errors(self):
        with tempfile.TemporaryDirectory() as temporary:
            widget = Path(temporary) / "AeroGrid"
            widget.mkdir()
            main = widget / "main.lua"
            main.write_text("return {\n    refresh = refresh,\n}\n")
            runner.install_progress_hook(
                widget, "AEROGRID_RUNNER_PROGRESS.txt", "AEROGRID_RUNNER_RELOAD.txt",
                "AEROGRID_RUNNER_UI.txt",
            )
            instrumented = main.read_text()
            self.assertIn('io.open("/AEROGRID_RUNNER_PROGRESS.txt", "w")', instrumented)
            self.assertIn("#(context.errors or {})", instrumented)
            self.assertIn("#(context.panels or {}) > 0", instrumented)
            self.assertIn("io.write(file,", instrumented)
            self.assertIn('io.open("/AEROGRID_RUNNER_RELOAD.txt", "w")', instrumented)
            self.assertIn("placement.colSpan", instrumented)
            self.assertIn("metric.label", instrumented)
            self.assertIn('io.open("/AEROGRID_RUNNER_UI.txt", "w")', instrumented)
            self.assertIn('"metric2-source=" .. tostring(second.source or "")', instrumented)
            self.assertIn('"geometry-resized="', instrumented)
            self.assertIn(r'}, "\n")', instrumented)

    def test_tutorial_actions_are_translated_to_touch_and_exit_key_inputs(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "inputs.txt"
            recipe, actions = runner.tutorial_actions(
                ROOT / "tools/video-recipes/add-move-resize-panel.json", path
            )
            self.assertEqual(recipe["ticks"], 14800)
            self.assertIn(
                {"tick": 5600, "type": "key", "button": 1, "state": "down"}, actions
            )
            self.assertIn(
                {"tick": 9600, "type": "touch", "x": 60, "y": 40, "state": "down"},
                actions,
            )
            self.assertIn(
                {"tick": 2500, "type": "touch", "x": 200, "y": 158, "state": "up"},
                actions,
            )

    def test_metric_workflow_uses_real_picker_and_keyboard_inputs(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "workflow.txt"
            recipe, actions = runner.metric_workflow_actions(
                ROOT / "tools/video-recipes/add-move-resize-panel.json", path
            )
            self.assertEqual(recipe["ticks"], 14800)
            self.assertIn(
                {"tick": 4250, "type": "touch", "x": 250, "y": 171, "state": "down"},
                actions,
            )
            self.assertIn(
                {"tick": 6250, "type": "touch", "x": 250, "y": 241, "state": "down"},
                actions,
            )
            for x, y in ((127, 204), (397, 178), (138, 178), (166, 204),
                         (332, 230), (89, 204), (139, 230)):
                with self.subTest(key=(x, y)):
                    self.assertTrue(any(
                        action["type"] == "touch" and action["x"] == x
                        and action["y"] == y and action["state"] == "down"
                        for action in actions
                    ))
            self.assertEqual(sum(
                action["tick"] >= 6400 and action["tick"] < 6600
                and action["type"] == "touch" and action["x"] == 447
                and action["y"] == 178 and action["state"] == "down"
                for action in actions
            ), len("speed"))
            self.assertEqual(sum(
                action["type"] == "key" and action["button"] == 1
                and action["state"] == "down" for action in actions
            ), 5)
            self.assertIn(
                {"tick": 7000, "type": "key", "button": 1, "state": "down"},
                actions,
            )
            for token in (
                "panels=1", "metric1-source=GSpd", "metric1-label=speed",
                "metrics-count=2", "metric2-source=GSpd+", "metric2-label=max",
                "drawer=panel", "drawer=none", "geometry-moved=true",
                "geometry-resized=true",
            ):
                with self.subTest(wait=token):
                    self.assertIn(
                        {"type": "wait", "token": token, "timeout_ticks": 1000},
                        [{key: value for key, value in action.items() if key != "tick"}
                         for action in actions],
                    )

    def test_reload_marker_parser_returns_persisted_state(self):
        with tempfile.TemporaryDirectory() as temporary:
            marker = Path(temporary) / "reload.txt"
            marker.write_text(
                "layout=RunnerLayout\nerrors=0\n"
                "panel=metric,1,0,3,2\n"
                "metric=GSpd,speed\nmetric=GSpd+,max\n"
            )
            self.assertEqual(runner.parse_reload_marker(marker), {
                "layout": "RunnerLayout",
                "errors": 0,
                "panels": [{
                    "type": "metric", "col": 1, "row": 0,
                    "colSpan": 3, "rowSpan": 2,
                }],
                "metrics": [
                    {"source": "GSpd", "label": "speed"},
                    {"source": "GSpd+", "label": "max"},
                ],
            })

    def test_selects_saved_layout_only_in_aerogrid_widget_options(self):
        with tempfile.TemporaryDirectory() as temporary:
            model = Path(temporary) / "model.yml"
            model.write_text(
                "unsignedValue: 1\n"
                "widgetName: AeroGrid\n"
                "   widgetData:\n"
                "      options:\n"
                "         0:\n"
                "            type: Unsigned\n"
                "            value:\n"
                "               unsignedValue: 1\n"
                "         1:\n"
                "            type: Unsigned\n"
                "            value:\n"
                "               unsignedValue: 7\n"
            )
            runner.select_saved_layout(model, 24)
            content = model.read_text()
            self.assertIn("unsignedValue: 24\n", content)
            self.assertEqual(content.count("unsignedValue: 1\n"), 1)
            self.assertIn("unsignedValue: 7\n", content)


if __name__ == "__main__":
    unittest.main()

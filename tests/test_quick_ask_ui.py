#!/usr/bin/env python3
"""Low-permission UI harness tests for Quick Ask."""

from __future__ import annotations

import json
import os
import subprocess
import tempfile
import time
import unittest
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parent.parent
APP_BINARY = Path(os.environ.get("QUICK_ASK_APP_BINARY", Path.home() / "Applications/Quick Ask.app/Contents/MacOS/Quick Ask"))
LAUNCH_AGENTS = [
    Path.home() / "Library/LaunchAgents/app.quickask.mac.plist",
]


def run_command(argv: list[str]) -> None:
    subprocess.run(argv, check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def activate_app(app_name: str) -> None:
    run_command(["open", "-a", app_name])


class QuickAskHarness:
    def __init__(self, *, enable_singleton: bool = False) -> None:
        self.temp_dir = tempfile.TemporaryDirectory(prefix="quick-ask-ui-")
        base = Path(self.temp_dir.name)
        self.state_path = base / "state.json"
        self.command_path = base / "command.json"
        self.process: subprocess.Popen[str] | None = None
        self.command_id = 0
        self.enable_singleton = enable_singleton
        self.stopped_agents = [path for path in LAUNCH_AGENTS if path.exists() and self._launch_agent_is_loaded(path)]

    def __enter__(self) -> "QuickAskHarness":
        self.stop_background_launch()
        self.kill_existing_app()
        env = os.environ.copy()
        env["QUICK_ASK_UI_TEST_MODE"] = "1"
        env["QUICK_ASK_UI_TEST_STATE_PATH"] = str(self.state_path)
        env["QUICK_ASK_UI_TEST_COMMAND_PATH"] = str(self.command_path)
        if self.enable_singleton:
            env["QUICK_ASK_UI_TEST_ENABLE_SINGLETON"] = "1"
        self.process = subprocess.Popen([str(APP_BINARY)], env=env)
        self.wait_for(lambda state: state["handledCommandID"] == 0)
        return self

    def __exit__(self, exc_type, exc, tb) -> None:
        if self.process and self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
        self.kill_existing_app()
        self.restore_background_launch()
        self.temp_dir.cleanup()

    def stop_background_launch(self) -> None:
        uid = str(os.getuid())
        for plist in self.stopped_agents:
            run_command(["launchctl", "bootout", f"gui/{uid}", str(plist)])

    def restore_background_launch(self) -> None:
        uid = str(os.getuid())
        for plist in self.stopped_agents:
            run_command(["launchctl", "bootstrap", f"gui/{uid}", str(plist)])

    def kill_existing_app(self) -> None:
        run_command(["pkill", "-f", str(APP_BINARY)])
        time.sleep(0.4)

    def _launch_agent_is_loaded(self, plist: Path) -> bool:
        label = plist.stem
        result = subprocess.run(
            ["launchctl", "print", f"gui/{os.getuid()}/{label}"],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        return result.returncode == 0

    def read_state(self) -> dict[str, Any]:
        if not self.state_path.exists():
            raise AssertionError("Quick Ask test state file is missing.")
        return json.loads(self.state_path.read_text())

    def wait_for(self, predicate, timeout: float = 8.0) -> dict[str, Any]:
        deadline = time.time() + timeout
        last_state: dict[str, Any] | None = None
        while time.time() < deadline:
            try:
                last_state = self.read_state()
            except Exception:
                time.sleep(0.05)
                continue
            if predicate(last_state):
                return last_state
            time.sleep(0.05)
        raise AssertionError(f"Timed out waiting for state. Last state: {last_state}")

    def command(self, action: str, *, text: str | None = None, shortcut: str | None = None) -> dict[str, Any]:
        self.command_id += 1
        payload = {
            "id": self.command_id,
            "action": action,
            "text": text,
            "shortcut": shortcut,
        }
        self.command_path.write_text(json.dumps(payload))
        state = self.wait_for(lambda state: state["handledCommandID"] >= self.command_id)
        time.sleep(0.12)
        return self.read_state()

    def launch_duplicate(self) -> subprocess.CompletedProcess[str]:
        env = os.environ.copy()
        env.pop("QUICK_ASK_UI_TEST_MODE", None)
        env.pop("QUICK_ASK_UI_TEST_STATE_PATH", None)
        env.pop("QUICK_ASK_UI_TEST_COMMAND_PATH", None)
        env.pop("QUICK_ASK_UI_TEST_ENABLE_SINGLETON", None)
        return subprocess.run(
            [str(APP_BINARY)],
            env=env,
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=5,
            text=True,
        )


class QuickAskUITests(unittest.TestCase):
    maxDiff = None

    def assertAlmostEqualPx(self, a: float, b: float, tolerance: float = 1.0) -> None:
        self.assertLessEqual(abs(a - b), tolerance, msg=f"{a} != {b} within {tolerance}px")

    def test_input_anchor_on_first_response(self) -> None:
        with QuickAskHarness() as app:
            baseline = app.command("show_panel")
            baseline_bottom_inset = baseline["inputBarBottomInset"]
            baseline_panel_y = baseline["panelFrame"]["y"]

            app.command("set_input", text="hello")
            generating = app.command("submit")
            self.assertTrue(generating["isGenerating"])
            self.assertGreaterEqual(generating["messageCount"], 2)

            completed = app.command("complete_generation", text="hi there")
            self.assertFalse(completed["isGenerating"])
            self.assertGreater(completed["historyAreaHeight"], 0)
            self.assertAlmostEqualPx(completed["inputBarBottomInset"], baseline_bottom_inset)
            self.assertAlmostEqualPx(completed["panelFrame"]["y"], baseline_panel_y)

    def test_history_grows_upward_and_caps(self) -> None:
        with QuickAskHarness() as app:
            baseline = app.command("show_panel")
            baseline_bottom_inset = baseline["inputBarBottomInset"]
            baseline_panel_y = baseline["panelFrame"]["y"]

            for index in range(14):
                app.command("set_input", text=f"user message {index}")
                app.command("submit")
                state = app.command(
                    "complete_generation",
                    text=("assistant reply " + str(index) + " ") * 30,
                )

            self.assertGreater(state["historyAreaHeight"], 100)
            self.assertLessEqual(state["historyAreaHeight"], 450.0)
            self.assertAlmostEqualPx(state["inputBarBottomInset"], baseline_bottom_inset)
            self.assertAlmostEqualPx(state["panelFrame"]["y"], baseline_panel_y)

    def test_cmd_n_keeps_input_bar_pinned(self) -> None:
        with QuickAskHarness() as app:
            app.command("show_panel")
            app.command("set_input", text="first")
            app.command("submit")
            before = app.command("complete_generation", text="reply")
            bottom_inset = before["inputBarBottomInset"]
            panel_y = before["panelFrame"]["y"]

            after = app.command("shortcut", shortcut="cmd_n")
            self.assertEqual(after["messageCount"], 0)
            self.assertEqual(after["queuedCount"], 0)
            self.assertAlmostEqualPx(after["inputBarBottomInset"], bottom_inset)
            self.assertAlmostEqualPx(after["panelFrame"]["y"], panel_y)

    def test_second_cmd_n_on_fresh_chat_clears_input_only(self) -> None:
        with QuickAskHarness() as app:
            app.command("show_panel")
            app.command("set_input", text="old draft")
            app.command("submit")
            app.command("complete_generation", text="reply")
            app.command("set_input", text="keep this draft")

            first_reset = app.command("shortcut", shortcut="cmd_n")
            self.assertEqual(first_reset["messageCount"], 0)
            self.assertEqual(first_reset["inputText"], "keep this draft")

            second_reset = app.command("shortcut", shortcut="cmd_n")
            self.assertEqual(second_reset["messageCount"], 0)
            self.assertEqual(second_reset["inputText"], "")

    def test_queue_and_cmd_enter_steer(self) -> None:
        with QuickAskHarness() as app:
            app.command("show_panel")
            app.command("set_input", text="first prompt")
            first = app.command("submit")
            self.assertTrue(first["isGenerating"])

            app.command("set_input", text="second prompt")
            queued = app.command("submit")
            self.assertEqual(queued["queuedCount"], 1)

            steered = app.command("shortcut", shortcut="cmd_enter")
            self.assertTrue(steered["isGenerating"])
            self.assertEqual(steered["queuedCount"], 0)
            self.assertGreaterEqual(steered["messageCount"], 3)

            done = app.command("complete_generation", text="second reply")
            self.assertFalse(done["isGenerating"])
            self.assertEqual(done["queuedCount"], 0)

    def test_cmd_enter_steers_current_input_ahead_of_existing_queue(self) -> None:
        with QuickAskHarness() as app:
            app.command("show_panel")
            app.command("set_input", text="first prompt")
            first = app.command("submit")
            self.assertTrue(first["isGenerating"])

            app.command("set_input", text="older queued prompt")
            queued = app.command("submit")
            self.assertEqual(queued["queuedCount"], 1)

            app.command("set_input", text="newer steered prompt")
            steered = app.command("shortcut", shortcut="cmd_enter")
            self.assertTrue(steered["isGenerating"])
            self.assertEqual(steered["queuedCount"], 1)

            app.command("complete_generation", text="newer steered reply")
            after_first_followup = app.command("complete_generation", text="older queued reply")
            self.assertFalse(after_first_followup["isGenerating"])
            self.assertEqual(after_first_followup["queuedCount"], 0)
            self.assertEqual(after_first_followup["messageCount"], 5)

    def test_cancel_clears_queued_prompts_without_stopping_active_reply(self) -> None:
        with QuickAskHarness() as app:
            app.command("show_panel")
            app.command("set_input", text="first prompt")
            first = app.command("submit")
            self.assertTrue(first["isGenerating"])

            app.command("set_input", text="second prompt")
            queued = app.command("submit")
            self.assertEqual(queued["queuedCount"], 1)
            self.assertTrue(queued["isGenerating"])

            canceled = app.command("clear_queue")
            self.assertEqual(canceled["queuedCount"], 0)
            self.assertTrue(canceled["isGenerating"])

            done = app.command("complete_generation", text="first reply")
            self.assertFalse(done["isGenerating"])
            self.assertEqual(done["queuedCount"], 0)
            self.assertEqual(done["messageCount"], 2)

    def test_history_window_shortcut(self) -> None:
        with QuickAskHarness() as app:
            app.command("show_panel")
            shown = app.command("shortcut", shortcut="cmd_shift_backslash")
            self.assertTrue(shown["historyWindowVisible"])
            hidden = app.command("shortcut", shortcut="cmd_shift_backslash")
            self.assertFalse(hidden["historyWindowVisible"])

    def test_hiding_panel_dismisses_history(self) -> None:
        with QuickAskHarness() as app:
            app.command("show_panel")
            shown = app.command("shortcut", shortcut="cmd_shift_backslash")
            self.assertTrue(shown["historyWindowVisible"])

            hidden = app.command("hide_panel")
            self.assertFalse(hidden["panelVisible"])
            self.assertFalse(hidden["historyWindowVisible"])

    def test_left_open_panel_does_not_steal_focus(self) -> None:
        with QuickAskHarness() as app:
            app.command("show_panel")
            activate_app("Finder")
            other_app_state = app.wait_for(
                lambda state: state["frontmostAppName"] != "Quick Ask" and not state["panelIsKeyWindow"]
            )
            baseline_focus_requests = other_app_state["focusRequestCount"]

            time.sleep(3.0)
            after_wait = app.read_state()
            self.assertTrue(after_wait["panelVisible"])
            self.assertFalse(after_wait["panelIsKeyWindow"])
            self.assertNotEqual(after_wait["frontmostAppName"], "Quick Ask")
            self.assertEqual(after_wait["focusRequestCount"], baseline_focus_requests)

            after_request = app.command("request_focus")
            self.assertTrue(after_request["panelVisible"])
            self.assertFalse(after_request["panelIsKeyWindow"])
            self.assertNotEqual(after_request["frontmostAppName"], "Quick Ask")
            self.assertEqual(after_request["focusRequestCount"], baseline_focus_requests + 1)

    def test_duplicate_launch_does_not_open_panel(self) -> None:
        with QuickAskHarness(enable_singleton=True) as app:
            initial = app.read_state()
            self.assertFalse(initial["panelVisible"])
            self.assertFalse(initial["historyWindowVisible"])

            duplicate = app.launch_duplicate()
            self.assertEqual(duplicate.returncode, 0)
            time.sleep(0.3)

            self.assertIsNotNone(app.process)
            self.assertIsNone(app.process.poll())

            after = app.read_state()
            self.assertFalse(after["panelVisible"])
            self.assertFalse(after["historyWindowVisible"])
            self.assertFalse(after["panelIsKeyWindow"])


if __name__ == "__main__":
    unittest.main(verbosity=2)

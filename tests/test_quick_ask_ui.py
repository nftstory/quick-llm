#!/usr/bin/env python3
"""Low-permission UI harness tests for Quick Ask."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
import uuid
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parent.parent
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

import quick_ask_shared as shared

os.environ.setdefault("QUICK_ASK_TEST_MASTER_KEY_B64", "MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY=")

APP_BINARY = Path(os.environ.get("QUICK_ASK_APP_BINARY", Path.home() / "Applications/Quick Ask.app/Contents/MacOS/Quick Ask"))
LAUNCH_AGENTS = [
    Path.home() / "Library/LaunchAgents/app.quickask.mac.plist",
]


def run_command(argv: list[str]) -> None:
    subprocess.run(argv, check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def activate_app(app_name: str) -> None:
    run_command(["open", "-a", app_name])


class QuickAskHarness:
    def __init__(
        self,
        *,
        enable_singleton: bool = False,
        initial_setup_complete: bool = True,
        seed_archive_dir: bool | None = None,
        force_setup_gate: bool = False,
        app_binary: Path | None = None,
        launch_agents: list[Path] | None = None,
        seed_defaults_enabled: bool = True,
        extra_env: dict[str, str] | None = None,
    ) -> None:
        self.temp_dir = tempfile.TemporaryDirectory(prefix="quick-ask-ui-")
        base = Path(self.temp_dir.name)
        self.state_path = base / "state.json"
        self.command_path = base / "command.json"
        self.archive_dir = base / "archives"
        self.process: subprocess.Popen[str] | None = None
        self.command_id = 0
        self.enable_singleton = enable_singleton
        self.initial_setup_complete = initial_setup_complete
        self.seed_archive_dir = initial_setup_complete if seed_archive_dir is None else seed_archive_dir
        self.force_setup_gate = force_setup_gate
        self.app_binary = app_binary or APP_BINARY
        self.launch_agents = launch_agents if launch_agents is not None else LAUNCH_AGENTS
        self.seed_defaults_enabled = seed_defaults_enabled
        self.extra_env = extra_env or {}
        self.defaults_suite = f"app.quickask.tests.{uuid.uuid4().hex}"
        self.stopped_agents = [path for path in self.launch_agents if path.exists() and self._launch_agent_is_loaded(path)]

    def __enter__(self) -> "QuickAskHarness":
        self.stop_background_launch()
        self.kill_existing_app()
        env = os.environ.copy()
        env["QUICK_ASK_UI_TEST_MODE"] = "1"
        env["QUICK_ASK_UI_TEST_STATE_PATH"] = str(self.state_path)
        env["QUICK_ASK_UI_TEST_COMMAND_PATH"] = str(self.command_path)
        env["QUICK_ASK_USER_DEFAULTS_SUITE"] = self.defaults_suite
        env["QUICK_ASK_TEST_MASTER_KEY_B64"] = "MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY="
        env.update(self.extra_env)
        if self.enable_singleton:
            env["QUICK_ASK_UI_TEST_ENABLE_SINGLETON"] = "1"
        if self.force_setup_gate:
            env["QUICK_ASK_UI_TEST_FORCE_SETUP_GATE"] = "1"
        if self.seed_defaults_enabled:
            self.seed_defaults()
        self.process = subprocess.Popen([str(self.app_binary)], env=env)
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
        self.clear_defaults()
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
        run_command(["pkill", "-f", str(self.app_binary)])
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

    def seed_defaults(self) -> None:
        self.archive_dir.mkdir(parents=True, exist_ok=True)
        run_command(["defaults", "delete", self.defaults_suite])
        run_command(["defaults", "write", self.defaults_suite, "QuickAskHistoryEnabled", "-bool", "YES"])
        if self.seed_archive_dir:
            run_command(["defaults", "write", self.defaults_suite, "QuickAskCustomArchiveDirectory", "-string", str(self.archive_dir)])
        if self.initial_setup_complete:
            run_command(["defaults", "write", self.defaults_suite, "QuickAskSetupCompleted", "-bool", "YES"])
        else:
            run_command(["defaults", "write", self.defaults_suite, "QuickAskSetupCompleted", "-bool", "NO"])

    def clear_defaults(self) -> None:
        run_command(["defaults", "delete", self.defaults_suite])

    @property
    def effective_archive_dir(self) -> Path:
        return self.archive_dir / "Quick Ask" / "sessions"

    def seed_history_session(self, session_id: str, preview: str, *, model_id: str = "claude::claude-opus-4-6") -> Path:
        store = shared.SessionStore(self.effective_archive_dir, session_id=session_id)
        payload = {
            "session_id": session_id,
            "created_at": "2026-03-29T12:00:00Z",
            "saved_at": "2026-03-29T12:00:00Z",
            "model": "Claude Opus 4.6",
            "model_id": model_id,
            "num_ctx": 0,
            "endpoint": {"label": "claude-cli-login", "base_url": "claude://login"},
            "source": "quick-ask",
            "messages": [
                {"role": "system", "content": "system"},
                {"role": "user", "content": preview},
                {"role": "assistant", "content": "reply"},
            ],
        }
        store.save(payload)
        return store.path

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
            [str(self.app_binary)],
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

            app.command("shortcut", shortcut="cmd_n")
            first_reset = app.wait_for(
                lambda state: state["messageCount"] == 0 and state["inputText"] == "keep this draft",
                timeout=5.0,
            )
            self.assertEqual(first_reset["messageCount"], 0)
            self.assertEqual(first_reset["inputText"], "keep this draft")

            app.command("shortcut", shortcut="cmd_n")
            second_reset = app.wait_for(
                lambda state: state["messageCount"] == 0 and state["inputText"] == "",
                timeout=5.0,
            )
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

    def test_per_item_queue_actions_target_only_selected_prompt(self) -> None:
        with QuickAskHarness() as app:
            app.command("show_panel")
            app.command("set_input", text="first prompt")
            app.command("submit")

            app.command("set_input", text="second prompt")
            app.command("submit")
            app.command("set_input", text="third prompt")
            queued = app.command("submit")
            self.assertEqual(queued["queuedPromptContents"], ["second prompt", "third prompt"])

            canceled = app.command("cancel_queue_item", text="second prompt")
            self.assertEqual(canceled["queuedPromptContents"], ["third prompt"])
            self.assertEqual(canceled["queuedCount"], 1)
            self.assertTrue(canceled["isGenerating"])

            steered = app.command("steer_queue_item", text="third prompt")
            self.assertEqual(steered["queuedPromptContents"], [])
            self.assertTrue(steered["isGenerating"])

            done = app.command("complete_generation", text="third reply")
            self.assertFalse(done["isGenerating"])
            self.assertEqual(done["queuedCount"], 0)
            self.assertGreaterEqual(done["messageCount"], 3)

    def test_history_window_shortcut(self) -> None:
        with QuickAskHarness() as app:
            app.command("show_panel")
            shown = app.command("shortcut", shortcut="cmd_shift_backslash")
            self.assertTrue(shown["historyWindowVisible"])
            hidden = app.command("shortcut", shortcut="cmd_shift_backslash")
            self.assertFalse(hidden["historyWindowVisible"])

    def test_history_delete_removes_saved_session_file(self) -> None:
        with QuickAskHarness() as app:
            first = app.seed_history_session("session-a", "first prompt")
            second = app.seed_history_session("session-b", "second prompt")
            self.assertTrue(first.exists())
            self.assertTrue(second.exists())

            shown = app.command("shortcut", shortcut="cmd_shift_backslash")
            self.assertTrue(shown["historyWindowVisible"])
            loaded = app.wait_for(lambda state: len(state["historySessionIDs"]) == 2, timeout=8.0)
            self.assertIn("session-a", loaded["historySessionIDs"])
            self.assertIn("session-b", loaded["historySessionIDs"])

            deleted = app.command("delete_history_session", text="session-a")
            self.assertIn("session-b", deleted["historySessionIDs"])
            final_state = app.wait_for(
                lambda state: "session-a" not in state["historySessionIDs"] and not first.exists(),
                timeout=8.0,
            )
            self.assertFalse(first.exists())
            self.assertIn("session-b", final_state["historySessionIDs"])
            self.assertNotIn("session-a", final_state["historySessionIDs"])

    def test_setup_gate_blocks_panel_until_history_is_configured(self) -> None:
        with QuickAskHarness(initial_setup_complete=False, force_setup_gate=True) as app:
            app.command("show_panel")
            gated = app.wait_for(lambda state: state["settingsWindowVisible"], timeout=8.0)
            self.assertFalse(gated["panelVisible"])
            self.assertTrue(gated["settingsWindowVisible"])

            app.command("set_archive_dir", text=str(app.archive_dir))
            after_continue = app.command("complete_setup")
            self.assertFalse(after_continue["settingsWindowVisible"])
            self.assertFalse(after_continue["setupRequired"])

    def test_archive_ready_state_allows_panel_without_forcing_setup_completion(self) -> None:
        with QuickAskHarness(initial_setup_complete=False, seed_archive_dir=True) as app:
            shown = app.command("show_panel")
            self.assertTrue(shown["panelVisible"])
            self.assertFalse(shown["settingsWindowVisible"])
            self.assertFalse(shown["setupRequired"])

    def test_setup_gate_allows_disabling_history_instead_of_picking_folder(self) -> None:
        with QuickAskHarness(initial_setup_complete=False, force_setup_gate=True) as app:
            gated = app.command("show_panel")
            self.assertTrue(gated["settingsWindowVisible"])
            self.assertTrue(gated["historyEnabled"])

            app.command("set_history_enabled", text="0")
            app.wait_for(lambda state: state["historyEnabled"] is False, timeout=5.0)
            app.command("complete_setup")
            after_continue = app.wait_for(
                lambda state: not state["settingsWindowVisible"] and not state["setupRequired"],
                timeout=5.0,
            )
            self.assertFalse(after_continue["settingsWindowVisible"])
            self.assertFalse(after_continue["setupRequired"])
            self.assertFalse(after_continue["historyEnabled"])

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

    def test_visible_panel_does_not_reset_after_idle_timeout(self) -> None:
        with QuickAskHarness() as app:
            app.command("show_panel")
            app.command("set_input", text="first prompt")
            app.command("submit")
            app.command("complete_generation", text="reply")

            after_timeout = app.command("force_idle_timeout_elapsed")
            self.assertTrue(after_timeout["panelVisible"])
            self.assertEqual(after_timeout["messageCount"], 2)

    def test_hidden_panel_resets_after_idle_timeout(self) -> None:
        with QuickAskHarness() as app:
            app.command("show_panel")
            app.command("set_input", text="first prompt")
            app.command("submit")
            app.command("complete_generation", text="reply")

            hidden = app.command("hide_panel")
            self.assertFalse(hidden["panelVisible"])

            after_timeout = app.command("force_idle_timeout_elapsed")
            self.assertFalse(after_timeout["panelVisible"])
            self.assertEqual(after_timeout["messageCount"], 0)
            self.assertEqual(after_timeout["inputText"], "")

    def test_panel_resize_is_available_only_after_conversation_starts_and_resets_on_reopen(self) -> None:
        with QuickAskHarness() as app:
            shown = app.command("show_panel")
            initial_width = shown["panelFrame"]["width"]
            initial_height = shown["panelFrame"]["height"]

            before_history = app.command("resize_panel", text="760|260")
            self.assertEqual(before_history["panelFrame"]["width"], initial_width)
            self.assertEqual(before_history["panelFrame"]["height"], initial_height)

            app.command("set_input", text="hello")
            app.command("submit")
            with_history = app.command("complete_generation", text="reply")
            self.assertEqual(with_history["messageCount"], 2)

            resized = app.command("resize_panel", text="760|260")
            self.assertAlmostEqualPx(resized["panelFrame"]["width"], 760.0)
            self.assertAlmostEqualPx(resized["panelFrame"]["height"], 260.0)

            app.command("hide_panel")
            restored = app.command("show_panel")
            self.assertAlmostEqualPx(restored["panelFrame"]["width"], 560.0)
            self.assertNotEqual(restored["panelFrame"]["height"], 260.0)

    def test_panel_vertical_resize_can_grow_downward_after_conversation_starts(self) -> None:
        with QuickAskHarness() as app:
            app.command("show_panel")
            app.command("set_input", text="hello")
            app.command("submit")
            with_history = app.command("complete_generation", text="reply")
            original_top = with_history["panelFrame"]["y"] + with_history["panelFrame"]["height"]

            resized = app.command("resize_panel", text="560|260|top")
            self.assertAlmostEqualPx(resized["panelFrame"]["height"], 260.0)
            resized_top = resized["panelFrame"]["y"] + resized["panelFrame"]["height"]
            self.assertAlmostEqualPx(resized_top, original_top)

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

    def test_cmd_comma_toggles_settings_window_and_keeps_it_on_screen(self) -> None:
        with QuickAskHarness() as app:
            shown = app.command("shortcut", shortcut="cmd_comma")
            self.assertTrue(shown["settingsWindowVisible"])
            self.assertGreaterEqual(shown["settingsFrame"]["height"], 320)
            self.assertLessEqual(shown["settingsFrame"]["height"], shown["screenVisibleHeight"] + 1.0)
            hidden = app.command("shortcut", shortcut="cmd_comma")
            self.assertFalse(hidden["settingsWindowVisible"])

    def test_show_shortcuts_window(self) -> None:
        with QuickAskHarness() as app:
            shown = app.command("show_shortcuts")
            self.assertTrue(shown["shortcutsWindowVisible"])
            hidden = app.command("shortcut", shortcut="cmd_w")
            self.assertFalse(hidden["shortcutsWindowVisible"])

    def test_cmd_w_hides_main_panel(self) -> None:
        with QuickAskHarness() as app:
            shown = app.command("show_panel")
            self.assertTrue(shown["panelVisible"])
            hidden = app.command("shortcut", shortcut="cmd_w")
            self.assertFalse(hidden["panelVisible"])

    def test_model_visibility_shows_chatgpt_modes_and_can_be_changed(self) -> None:
        with QuickAskHarness() as app:
            state = app.command("show_panel")
            state = app.wait_for(lambda current: len(current["visibleModelIDs"]) > 0, timeout=8.0)
            self.assertIn("codex::gpt-5.4-instant", state["visibleModelIDs"])
            self.assertIn("codex::gpt-5.4-medium", state["visibleModelIDs"])

            app.command("set_model_visible", text="codex::gpt-5.4-medium|0")
            hidden = app.wait_for(
                lambda current: "codex::gpt-5.4-medium" not in current["visibleModelIDs"],
                timeout=8.0,
            )
            self.assertNotIn("codex::gpt-5.4-medium", hidden["visibleModelIDs"])

            app.command("set_model_visible", text="codex::gpt-5.4-medium|1")
            enabled = app.wait_for(
                lambda current: "codex::gpt-5.4-medium" in current["visibleModelIDs"],
                timeout=8.0,
            )
            self.assertIn("codex::gpt-5.4-medium", enabled["visibleModelIDs"])

    def test_cmd_brackets_cycle_models_from_focused_input(self) -> None:
        with QuickAskHarness() as app:
            app.command("show_panel")
            app.wait_for(lambda current: len(current["visibleModelIDs"]) >= 2, timeout=8.0)

            app.command("select_model", text="claude::claude-opus-4-6")
            next_model = app.command("shortcut", shortcut="cmd_right_bracket")
            self.assertEqual(next_model["selectedModel"], "Sonnet 4.6")

            previous_model = app.command("shortcut", shortcut="cmd_left_bracket")
            self.assertEqual(previous_model["selectedModel"], "Opus 4.6")

            wrapped = app.command("shortcut", shortcut="cmd_left_bracket")
            self.assertEqual(wrapped["selectedModel"], "Qwen 2.5 14B")

    def test_ctrl_tab_cycles_visible_models_from_focused_input(self) -> None:
        with QuickAskHarness() as app:
            app.command("show_panel")
            app.wait_for(lambda current: len(current["visibleModelIDs"]) >= 6, timeout=8.0)

            app.command("select_model", text="claude::claude-opus-4-6")

            sonnet = app.command("shortcut", shortcut="ctrl_tab")
            self.assertEqual(sonnet["selectedModel"], "Sonnet 4.6")

            instant = app.command("shortcut", shortcut="ctrl_tab")
            self.assertEqual(instant["selectedModel"], "ChatGPT 5.4 Instant")

            medium = app.command("shortcut", shortcut="ctrl_tab")
            self.assertEqual(medium["selectedModel"], "ChatGPT 5.4 Medium")

            gemini = app.command("shortcut", shortcut="ctrl_tab")
            self.assertEqual(gemini["selectedModel"], "Gemini 3 Flash")

            flash_lite = app.command("shortcut", shortcut="ctrl_tab")
            self.assertEqual(flash_lite["selectedModel"], "Gemini Flash Lite")

            previous = app.command("shortcut", shortcut="ctrl_shift_tab")
            self.assertEqual(previous["selectedModel"], "Gemini 3 Flash")

    def test_switching_models_preserves_history_and_updates_next_turn_selection(self) -> None:
        with QuickAskHarness() as app:
            app.command("show_panel")
            app.wait_for(lambda current: "codex::gpt-5.4-instant" in current["visibleModelIDs"], timeout=8.0)

            app.command("set_input", text="first prompt")
            app.command("submit")
            app.command("complete_generation", text="first reply")

            switched = app.command("select_model", text="codex::gpt-5.4-medium")
            self.assertEqual(switched["selectedModel"], "ChatGPT 5.4 Medium")
            self.assertEqual(switched["messageCount"], 2)

            app.command("set_input", text="second prompt")
            in_flight = app.command("submit")
            self.assertTrue(in_flight["isGenerating"])
            self.assertEqual(in_flight["selectedModel"], "ChatGPT 5.4 Medium")
            self.assertEqual(in_flight["messageCount"], 4)

    def test_offline_defaults_to_best_visible_ollama_model(self) -> None:
        with QuickAskHarness(extra_env={"QUICK_ASK_UI_TEST_NETWORK_ONLINE": "0"}) as app:
            shown = app.command("show_panel")
            ready = app.wait_for(
                lambda current: len(current["visibleModelIDs"]) > 0 and current["selectedModel"] == "Qwen 2.5 14B",
                timeout=8.0,
            )
            self.assertEqual(ready["selectedModel"], "Qwen 2.5 14B")
            self.assertIn("ollama::qwen2.5:14b", ready["visibleModelIDs"])
            self.assertTrue(shown["panelVisible"])

    def test_failed_turn_surfaces_retry_and_replays_prompt_without_duplication(self) -> None:
        with QuickAskHarness() as app:
            app.command("show_panel")
            app.command("set_input", text="ebitda vs the other thing")
            app.command("submit")

            failed = app.command(
                "fail_generation",
                text='Failed to authenticate. API Error: 401 {"type":"error","error":{"type":"authentication_error","message":"OAuth token has expired. Please obtain a new token or refresh your existing token."}}',
            )
            self.assertFalse(failed["isGenerating"])
            self.assertTrue(failed["retryAvailable"])
            self.assertIn("could not authenticate", failed["statusText"].lower())
            self.assertEqual(failed["messageCount"], 1)

            app.command("select_model", text="ollama::qwen2.5:14b")
            retried = app.command("retry_failed_turn")
            self.assertTrue(retried["isGenerating"])
            self.assertFalse(retried["retryAvailable"])
            self.assertEqual(retried["selectedModel"], "Qwen 2.5 14B")
            self.assertEqual(retried["messageCount"], 2)

            completed = app.command("complete_generation", text="Here is the retry reply.")
            self.assertFalse(completed["isGenerating"])
            self.assertEqual(completed["messageCount"], 2)
            self.assertEqual(completed["statusText"], "")


if __name__ == "__main__":
    unittest.main(verbosity=2)

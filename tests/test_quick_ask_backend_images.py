#!/usr/bin/env python3
"""Attachment/image regression tests for Quick Ask backend."""

from __future__ import annotations

import base64
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parent.parent
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

import quick_ask_backend as backend


def sample_attachment(filename: str = "chart.png", payload: bytes = b"fake-image-bytes") -> dict[str, str]:
    return {
        "filename": filename,
        "mimeType": "image/png",
        "dataBase64": base64.b64encode(payload).decode("ascii"),
    }


class BackendImageSupportTests(unittest.TestCase):
    def test_read_history_from_stdin_keeps_attachment_only_messages(self) -> None:
        payload = {
            "history": [
                {
                    "role": "user",
                    "content": "",
                    "attachments": [sample_attachment()],
                }
            ]
        }
        with mock.patch("sys.stdin", io.StringIO(json.dumps(payload))):
            history = backend.read_history_from_stdin()

        self.assertEqual(len(history), 1)
        self.assertEqual(history[0]["role"], "user")
        self.assertEqual(history[0]["content"], "")
        self.assertEqual(len(history[0]["attachments"]), 1)

    def test_session_preview_uses_attachment_summary_when_no_text_exists(self) -> None:
        preview = backend.session_preview(
            [
                {
                    "role": "user",
                    "content": "",
                    "attachments": [sample_attachment("one.png"), sample_attachment("two.png")],
                }
            ]
        )
        self.assertEqual(preview, "2 images")

    def test_build_prompt_mentions_attached_images(self) -> None:
        prompt = backend.build_prompt(
            [
                {
                    "role": "user",
                    "content": "what's in this?",
                    "attachments": [sample_attachment("receipt.png")],
                }
            ]
        )

        self.assertIn("Attached image #1 (receipt.png).", prompt)
        self.assertIn("User: what's in this?", prompt)

    def test_ollama_messages_include_images(self) -> None:
        messages = backend.ollama_messages_from_history(
            [
                {
                    "role": "user",
                    "content": "describe this",
                    "attachments": [sample_attachment()],
                }
            ]
        )

        self.assertEqual(messages[1]["role"], "user")
        self.assertEqual(messages[1]["content"], "describe this")
        self.assertEqual(len(messages[1]["images"]), 1)

    def test_codex_shell_invocation_materializes_attachment_files(self) -> None:
        history = [
            {
                "role": "user",
                "content": "what is in this chart?",
                "attachments": [sample_attachment("chart.png", b"chart-bytes")],
            }
        ]
        with tempfile.TemporaryDirectory(prefix="quick-ask-images-test-") as temp_dir:
            with mock.patch.object(backend, "command_path", return_value="/opt/homebrew/bin/codex"):
                argv, _safe_cwd = backend.codex_shell_invocation(
                    "gpt-5.4",
                    history,
                    attachment_dir=Path(temp_dir),
                )
                image_flag_index = argv.index("-i")
                image_path = Path(argv[image_flag_index + 1])
                self.assertTrue(image_path.exists())
                self.assertEqual(image_path.read_bytes(), b"chart-bytes")

    def test_claude_shell_invocation_allows_read_for_attachment_files(self) -> None:
        history = [
            {
                "role": "user",
                "content": "what is in this image?",
                "attachments": [sample_attachment("receipt.png", b"receipt-bytes")],
            }
        ]
        with tempfile.TemporaryDirectory(prefix="quick-ask-claude-test-") as temp_dir:
            with mock.patch.object(backend, "SAFE_CWD", Path(temp_dir)):
                with mock.patch.object(backend, "command_path", return_value="/opt/homebrew/bin/claude"):
                    argv, _safe_cwd = backend.claude_shell_invocation(
                        "claude-opus-4-6",
                        history,
                        attachment_dir=Path(temp_dir) / "attachments",
                    )

                    self.assertIn("--allowedTools", argv)
                    self.assertIn("Read", argv)
                    prompt = argv[argv.index("-p") + 1]
                    self.assertIn("Local image path:", prompt)
                    self.assertIn("receipt.png", prompt)
                    materialized_path = Path(prompt.split("Local image path:", 1)[1].splitlines()[0].strip())
                    self.assertTrue(materialized_path.exists())
                    self.assertEqual(materialized_path.read_bytes(), b"receipt-bytes")

    def test_gemini_shell_invocation_uses_workspace_relative_attachment_refs(self) -> None:
        history = [
            {
                "role": "user",
                "content": "describe this image",
                "attachments": [sample_attachment("chart.png", b"chart-bytes")],
            }
        ]
        with tempfile.TemporaryDirectory(prefix="quick-ask-gemini-test-") as temp_dir:
            safe_cwd = Path(temp_dir)
            attachment_dir = safe_cwd / "attachments"
            with mock.patch.object(backend, "SAFE_CWD", safe_cwd):
                with mock.patch.object(backend, "command_path", return_value="/opt/homebrew/bin/gemini"):
                    argv, _safe_cwd = backend.gemini_shell_invocation(
                        "gemini-2.5-flash-lite",
                        history,
                        attachment_dir=attachment_dir,
                    )

                    prompt = argv[argv.index("-p") + 1]
                    self.assertIn("@attachments/001-chart.png", prompt)
                    self.assertTrue((attachment_dir / "001-chart.png").exists())
                    self.assertEqual((attachment_dir / "001-chart.png").read_bytes(), b"chart-bytes")

    def test_handle_chat_routes_image_turns_to_claude(self) -> None:
        history = [
            {
                "role": "user",
                "content": "what is this?",
                "attachments": [sample_attachment()],
            }
        ]
        with mock.patch.object(backend, "read_history_from_stdin", return_value=history):
            with mock.patch.object(backend, "stream_claude", return_value=0) as stream_claude:
                result = backend.handle_chat("claude::claude-opus-4-6")

        self.assertEqual(result, 0)
        stream_claude.assert_called_once_with("claude-opus-4-6", history)

    def test_handle_chat_routes_image_turns_to_gemini(self) -> None:
        history = [
            {
                "role": "user",
                "content": "what is this?",
                "attachments": [sample_attachment()],
            }
        ]
        with mock.patch.object(backend, "read_history_from_stdin", return_value=history):
            with mock.patch.object(backend, "stream_gemini", return_value=0) as stream_gemini:
                result = backend.handle_chat("gemini::gemini-3-flash-preview")

        self.assertEqual(result, 0)
        stream_gemini.assert_called_once_with("gemini-3-flash-preview", history)


if __name__ == "__main__":
    unittest.main(verbosity=2)

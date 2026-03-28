#!/usr/bin/env python3
"""Backend bridge for the Quick Ask macOS panel."""

from __future__ import annotations

import argparse
import contextlib
import http.client
import json
import os
import pathlib
import shlex
import subprocess
import sys
from typing import Any

ROOT = pathlib.Path(__file__).resolve().parent
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

import quick_ask_shared as shared


QUICK_SYSTEM_PROMPT = (
    "You are a quick-question assistant in a tiny floating Mac panel. "
    "Answer clearly, naturally, and directly. "
    "Be concise by default unless the user explicitly asks for depth. "
    "Do not use preambles, bullet spam, or stage directions unless requested."
)
SAFE_CWD = pathlib.Path.home() / ".local/state/quick-ask/claude-scratch"
BLOCKED_PROVIDER_ENV_KEYS = {
    "ANTHROPIC_API_KEY",
    "OPENAI_API_KEY",
    "OPENROUTER_API_KEY",
    "GOOGLE_API_KEY",
    "GEMINI_API_KEY",
    "MISTRAL_API_KEY",
    "COHERE_API_KEY",
    "XAI_API_KEY",
    "DEEPSEEK_API_KEY",
    "PERPLEXITY_API_KEY",
    "TOGETHER_API_KEY",
    "FIREWORKS_API_KEY",
}

CLAUDE_MODELS: list[dict[str, Any]] = [
    {
        "id": "claude::claude-opus-4-6",
        "provider": "claude",
        "model": "claude-opus-4-6",
        "label": "Claude Opus 4.6",
        "short_label": "Opus 4.6",
        "hint": "default, strongest prose",
        "default": True,
    },
    {
        "id": "claude::claude-sonnet-4-6",
        "provider": "claude",
        "model": "claude-sonnet-4-6",
        "label": "Claude Sonnet 4.6",
        "short_label": "Sonnet 4.6",
        "hint": "faster remote Claude",
        "default": False,
    },
]

FRIENDLY_OLLAMA_NAMES = {
    "eva-qwen2.5:14b-q8": "EVA Q8",
    "type32/eva-qwen-2.5-14b:latest": "EVA 14B",
    "qwen2.5:32b": "Qwen 2.5 32B",
    "qwen2.5:14b": "Qwen 2.5 14B",
    "magnum-v4:12b-q8": "Magnum V4 Q8",
    "LESSTHANSUPER/MAGNUM_V4-Mistral_Small:12b_Q4_K_S": "Magnum Small",
    "hermes3:8b": "Hermes 3 8B",
    "qwen3:30b": "Qwen 3 30B",
    "richardyoung/qwen3-14b-abliterated:Q4_K_M": "Qwen 3 Ablit",
}


def emit(payload: dict[str, Any]) -> None:
    print(json.dumps(payload, ensure_ascii=True), flush=True)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Quick Ask backend bridge")
    subparsers = parser.add_subparsers(dest="command", required=True)

    subparsers.add_parser("models", help="List available models for the panel.")

    history_parser = subparsers.add_parser("history", help="List encrypted Quick Ask sessions.")
    history_parser.add_argument("--limit", type=int, default=100, help="Maximum number of sessions to return.")

    load_parser = subparsers.add_parser("load", help="Load an encrypted Quick Ask session.")
    load_parser.add_argument("--session-id", required=True, help="Session identifier to load.")

    chat_parser = subparsers.add_parser("chat", help="Stream a chat reply.")
    chat_parser.add_argument("--model-id", required=True, help="Combined provider/model identifier.")

    save_parser = subparsers.add_parser("save", help="Persist an encrypted transcript.")
    save_parser.add_argument("--session-id", required=True, help="Stable session identifier.")
    save_parser.add_argument("--created-at", required=True, help="Session creation timestamp.")
    save_parser.add_argument("--model-id", required=True, help="Combined provider/model identifier.")
    return parser.parse_args()


def friendly_ollama_name(model: str) -> str:
    return FRIENDLY_OLLAMA_NAMES.get(model, model)


def list_available_models() -> list[dict[str, Any]]:
    models = [dict(model) for model in CLAUDE_MODELS]
    try:
        endpoint = shared.resolve_ollama_endpoint(ensure_local=True, prefer_env=False)
        records = shared.list_model_records(endpoint["base_url"])
    except Exception:
        return models

    for record in records:
        name = str(record.get("name") or "").strip()
        if not name:
            continue
        label = friendly_ollama_name(name)
        models.append(
            {
                "id": f"ollama::{name}",
                "provider": "ollama",
                "model": name,
                "label": label,
                "short_label": label,
                "hint": None,
                "endpoint": endpoint.get("label", endpoint["base_url"]),
                "default": False,
            }
        )
    return models


def build_prompt(history: list[dict[str, str]]) -> str:
    if not history:
        return "The user has not said anything yet."

    lines: list[str] = [
        "Continue this conversation naturally.",
        "",
        "Conversation:",
    ]
    for message in history:
        role = str(message.get("role") or "").strip().lower()
        content = str(message.get("content") or "").strip()
        if role not in {"user", "assistant"} or not content:
            continue
        prefix = "User" if role == "user" else "Assistant"
        lines.append(f"{prefix}: {content}")
    lines.extend(["", "Assistant:"])
    return "\n".join(lines)


def compact_preview(text: str, limit: int = 140) -> str:
    normalized = " ".join(text.split())
    if len(normalized) <= limit:
        return normalized
    return normalized[: max(0, limit - 1)].rstrip() + "…"


def session_preview(messages: list[dict[str, str]]) -> str:
    for message in reversed(messages):
        role = str(message.get("role") or "").strip().lower()
        if role == "system":
            continue
        content = str(message.get("content") or "").strip()
        if content:
            return compact_preview(content)
    return ""


def subscription_only_env() -> dict[str, str]:
    env = dict(os.environ)
    for key in BLOCKED_PROVIDER_ENV_KEYS:
        env.pop(key, None)
    return env


def claude_shell_invocation(model: str, history: list[dict[str, str]]) -> tuple[list[str], pathlib.Path]:
    prompt = build_prompt(history)
    claude_path = pathlib.Path.home() / ".local/bin/claude"
    SAFE_CWD.mkdir(parents=True, exist_ok=True)
    argv = [
        str(claude_path),
        "-p",
        prompt,
        "--model",
        model,
        "--effort",
        "low",
        "--no-session-persistence",
        "--permission-mode",
        "dontAsk",
        "--no-chrome",
        "--output-format",
        "stream-json",
        "--verbose",
        "--include-partial-messages",
        "--tools",
        "",
        "--disable-slash-commands",
        "--setting-sources",
        "user",
        "--mcp-config",
        '{"mcpServers":{}}',
        "--strict-mcp-config",
        "--system-prompt",
        QUICK_SYSTEM_PROMPT,
    ]
    return ["/bin/zsh", "-lc", " ".join(shlex.quote(part) for part in argv)], SAFE_CWD


def stream_claude(model: str, history: list[dict[str, str]]) -> int:
    command, safe_cwd = claude_shell_invocation(model, history)
    proc = subprocess.Popen(
        command,
        cwd=str(safe_cwd),
        env=subscription_only_env(),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        stdin=subprocess.DEVNULL,
        text=True,
        bufsize=1,
    )

    assert proc.stdout is not None
    streamed_any = False
    try:
        for raw_line in proc.stdout:
            line = raw_line.strip()
            if not line:
                continue
            try:
                payload = json.loads(line)
            except json.JSONDecodeError:
                continue

            if payload.get("type") == "stream_event":
                event = payload.get("event") or {}
                delta = event.get("delta") or {}
                text = delta.get("text")
                if isinstance(text, str) and text:
                    emit({"type": "chunk", "text": text})
                    streamed_any = True
                continue

            if payload.get("type") == "assistant":
                continue

            if payload.get("type") == "result":
                if payload.get("is_error"):
                    emit({"type": "error", "message": str(payload.get("result") or "Claude request failed.")})
                    return 1
                if not streamed_any:
                    result_text = str(payload.get("result") or "")
                    if result_text:
                        emit({"type": "chunk", "text": result_text})
                emit({"type": "done"})
                return 0
    except KeyboardInterrupt:
        proc.kill()
        raise

    stderr = ""
    if proc.stderr is not None:
        stderr = proc.stderr.read().strip()
    proc.wait()
    if proc.returncode != 0:
        emit({"type": "error", "message": stderr or f"Claude exited with status {proc.returncode}."})
        return proc.returncode
    emit({"type": "done"})
    return 0


def ollama_messages_from_history(history: list[dict[str, str]]) -> list[dict[str, str]]:
    messages: list[dict[str, str]] = [{"role": "system", "content": QUICK_SYSTEM_PROMPT}]
    for message in history:
        role = str(message.get("role") or "").strip().lower()
        content = str(message.get("content") or "").strip()
        if role not in {"user", "assistant"} or not content:
            continue
        messages.append({"role": role, "content": content})
    return messages


def open_ollama_connection(base_url: str) -> http.client.HTTPConnection:
    conn, _scheme = shared.connection_for_base_url(base_url, timeout=600)
    return conn


def stream_ollama_once(endpoint: dict[str, str], model: str, history: list[dict[str, str]]) -> tuple[int, bool]:
    body = json.dumps(
        {
            "model": model,
            "messages": ollama_messages_from_history(history),
            "think": False,
            "stream": True,
            "options": {
                "temperature": 0.7,
                "num_ctx": 8192,
            },
            "keep_alive": "30m",
        }
    )

    conn = open_ollama_connection(endpoint["base_url"])
    streamed_any = False
    try:
        conn.request(
            "POST",
            "/api/chat",
            body=body,
            headers={"Content-Type": "application/json"},
        )
        response = conn.getresponse()
        if response.status != 200:
            text = response.read().decode("utf-8", errors="replace")
            raise RuntimeError(f"Ollama error {response.status}: {text}")

        while True:
            line = response.readline()
            if not line:
                break
            line = line.strip()
            if not line:
                continue
            payload = json.loads(line)
            text = str((payload.get("message") or {}).get("content") or "")
            if text:
                emit({"type": "chunk", "text": text})
                streamed_any = True
            if payload.get("done"):
                emit({"type": "done"})
                return 0, streamed_any
    finally:
        with contextlib.suppress(Exception):
            conn.close()
    emit({"type": "done"})
    return 0, streamed_any


def stream_ollama(model: str, history: list[dict[str, str]]) -> int:
    endpoint = shared.resolve_ollama_endpoint(ensure_local=True, prefer_env=False)
    try:
        code, streamed_any = stream_ollama_once(endpoint, model, history)
        return code
    except Exception as exc:
        if endpoint.get("kind") == "remote":
            fallback = shared.resolve_ollama_endpoint(ensure_local=True, prefer_env=False)
            if fallback.get("kind") != endpoint.get("kind"):
                try:
                    code, streamed_any = stream_ollama_once(fallback, model, history)
                    return code
                except Exception as fallback_exc:
                    emit({"type": "error", "message": str(fallback_exc)})
                    return 1
        emit({"type": "error", "message": str(exc)})
        return 1


def read_history_from_stdin() -> list[dict[str, str]]:
    raw = sys.stdin.read().strip()
    if not raw:
        return []
    payload = json.loads(raw)
    history = payload.get("history", payload)
    if not isinstance(history, list):
        raise RuntimeError("Expected a history array on stdin.")
    cleaned: list[dict[str, str]] = []
    for item in history:
        if not isinstance(item, dict):
            continue
        role = str(item.get("role") or "").strip().lower()
        content = str(item.get("content") or "").strip()
        if role not in {"user", "assistant"} or not content:
            continue
        cleaned.append({"role": role, "content": content})
    return cleaned


def handle_models() -> int:
    emit({"type": "models", "models": list_available_models()})
    return 0


def handle_history(limit: int) -> int:
    base_dir = shared.default_save_dir()
    sessions: list[dict[str, Any]] = []
    for path in sorted(base_dir.glob("*.enc.json"), reverse=True):
        try:
            payload = shared.load_payload_from_path(path)
        except Exception:
            continue

        if str(payload.get("source") or "").strip() not in {"quick-ask", "quick_ask"}:
            continue

        messages = payload.get("messages") or []
        if not isinstance(messages, list):
            messages = []

        cleaned_messages = [
            message
            for message in messages
            if isinstance(message, dict)
            and str(message.get("role") or "").strip().lower() in {"user", "assistant"}
        ]
        session_id = str(payload.get("session_id") or path.name.removesuffix(".enc.json") or "")
        endpoint = payload.get("endpoint")
        endpoint_label = str(endpoint.get("label") or "") if isinstance(endpoint, dict) else ""
        sessions.append(
            {
                "session_id": session_id,
                "created_at": str(payload.get("created_at") or ""),
                "saved_at": str(payload.get("saved_at") or ""),
                "model": str(payload.get("model") or ""),
                "model_id": str(payload.get("model_id") or ""),
                "endpoint_label": endpoint_label,
                "message_count": len(cleaned_messages),
                "preview": session_preview(cleaned_messages),
            }
        )

    sessions.sort(key=lambda item: (item.get("saved_at") or item.get("created_at") or "", item.get("session_id") or ""), reverse=True)
    emit({"type": "history", "sessions": sessions[: max(0, limit)]})
    return 0


def handle_load(session_id: str) -> int:
    base_dir = shared.default_save_dir()
    path = shared.resolve_session_path(base_dir, session_id)
    payload = shared.load_payload_from_path(path)
    emit({"type": "session", "session": payload})
    return 0


def handle_chat(model_id: str) -> int:
    history = read_history_from_stdin()
    if "::" not in model_id:
        emit({"type": "error", "message": f"Malformed model id: {model_id}"})
        return 1

    provider, model = model_id.split("::", 1)
    if provider == "claude":
        return stream_claude(model, history)
    if provider == "ollama":
        return stream_ollama(model, history)

    emit({"type": "error", "message": f"Unknown provider: {provider}"})
    return 1


def transcript_model_label(model_id: str) -> str:
    provider, model = model_id.split("::", 1)
    if provider == "claude":
        for option in CLAUDE_MODELS:
            if option["id"] == model_id:
                return str(option["label"])
        return model
    return friendly_ollama_name(model)


def transcript_endpoint(model_id: str) -> dict[str, str]:
    provider, model = model_id.split("::", 1)
    if provider == "claude":
        return {
            "kind": "remote",
            "label": "claude-cli-login",
            "base_url": "claude://login",
        }

    try:
        endpoint = shared.resolve_ollama_endpoint(ensure_local=True, prefer_env=False)
    except Exception:
        return {
            "kind": "local",
            "label": "ollama",
            "base_url": "ollama://unknown",
        }
    return endpoint


def handle_save(session_id: str, created_at: str, model_id: str) -> int:
    history = read_history_from_stdin()
    messages = [{"role": "system", "content": QUICK_SYSTEM_PROMPT}, *history]
    payload = {
        "session_id": session_id,
        "created_at": created_at,
        "model": transcript_model_label(model_id),
        "model_id": model_id,
        "num_ctx": 0,
        "endpoint": transcript_endpoint(model_id),
        "source": "quick-ask",
        "messages": messages,
    }
    store = shared.SessionStore(shared.default_save_dir(), session_id=session_id)
    store.save(payload)
    emit({"type": "saved", "path": str(store.path)})
    return 0


def main() -> int:
    args = parse_args()
    if args.command == "models":
        return handle_models()
    if args.command == "history":
        return handle_history(args.limit)
    if args.command == "load":
        return handle_load(args.session_id)
    if args.command == "chat":
        return handle_chat(args.model_id)
    if args.command == "save":
        return handle_save(args.session_id, args.created_at, args.model_id)
    return 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except BrokenPipeError:
        raise SystemExit(0)

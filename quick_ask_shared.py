#!/usr/bin/env python3
"""Shared storage and Ollama helpers for Quick Ask."""

from __future__ import annotations

import base64
import datetime as dt
import getpass
import gzip
import hashlib
import hmac
import http.client
import json
import os
import pathlib
import secrets
import subprocess
import urllib.request
import uuid
from urllib.parse import urlparse

KEYCHAIN_SERVICE = "local-chat-transcript-key"
KEYCHAIN_LABEL = "local-chat-transcript-key (llm)"
ENCRYPTION_FORMAT = "local-chat-encrypted-v1"
ENC_INFO = b"local-chat-aes-256-ctr"
MAC_INFO = b"local-chat-hmac-sha256"
ROUTING_CONFIG_FILE = "routing.conf"

MODEL_PRIORITY = [
    "eva-qwen2.5:14b-q8",
    "type32/eva-qwen-2.5-14b:latest",
    "qwen2.5:32b",
    "qwen2.5:14b",
    "magnum-v4:12b-q8",
    "LESSTHANSUPER/MAGNUM_V4-Mistral_Small:12b_Q4_K_S",
    "hermes3:8b",
    "qwen3:30b",
    "richardyoung/qwen3-14b-abliterated:Q4_K_M",
]


def b64e(data: bytes) -> str:
    return base64.b64encode(data).decode("ascii")


def b64d(data: str) -> bytes:
    return base64.b64decode(data.encode("ascii"))


def llm_state_dir() -> pathlib.Path:
    return pathlib.Path(os.environ.get("XDG_STATE_HOME", pathlib.Path.home() / ".local/state")) / "llm"


def normalize_base_url(base_url: str) -> str:
    return base_url.rstrip("/")


def default_local_ollama_url() -> str:
    host = os.environ.get("OLLAMA_HOST", "127.0.0.1")
    port = os.environ.get("OLLAMA_PORT", "11434")
    return normalize_base_url(os.environ.get("OLLAMA_LOCAL_URL", f"http://{host}:{port}"))


def default_remote_ollama_url() -> str:
    return normalize_base_url(
        os.environ.get("OLLAMA_REMOTE_URL")
        or os.environ.get("LLM_REMOTE_OLLAMA_URL", "")
    )


def load_key_value_config(path: pathlib.Path) -> dict[str, str]:
    data: dict[str, str] = {}
    if not path.exists():
        return data

    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        data[key.strip()] = value.strip().strip('"').strip("'")
    return data


def routing_config_path() -> pathlib.Path:
    return llm_state_dir() / ROUTING_CONFIG_FILE


def base_url_to_label(kind: str, base_url: str) -> str:
    return f"{kind}: {base_url}"


def is_local_ollama_url(base_url: str) -> bool:
    parsed = urlparse(base_url)
    return parsed.hostname in {"127.0.0.1", "localhost", "::1"}


def endpoint_is_available(base_url: str, timeout: float = 2.0) -> bool:
    url = f"{normalize_base_url(base_url)}/api/tags"
    try:
        with urllib.request.urlopen(url, timeout=timeout) as response:
            response.read(1)
        return True
    except Exception:
        return False


def ensure_local_ollama_running() -> None:
    if endpoint_is_available(default_local_ollama_url()):
        return

    state_dir = llm_state_dir()
    state_dir.mkdir(parents=True, exist_ok=True)
    log_file = state_dir / "ollama-serve.log"
    subprocess.Popen(
        ["nohup", "ollama", "serve"],
        stdout=log_file.open("a"),
        stderr=subprocess.STDOUT,
        stdin=subprocess.DEVNULL,
        start_new_session=True,
    )

    for _ in range(40):
        if endpoint_is_available(default_local_ollama_url()):
            return
        import time
        time.sleep(0.5)


def load_routing_config() -> dict[str, str]:
    config = {
        "mode": "remote-first",
        "local_url": default_local_ollama_url(),
        "remote_url": default_remote_ollama_url(),
    }
    config.update(load_key_value_config(routing_config_path()))
    config["mode"] = config.get("mode", "remote-first") or "remote-first"
    config["local_url"] = normalize_base_url(config.get("local_url") or default_local_ollama_url())
    config["remote_url"] = normalize_base_url(config.get("remote_url") or default_remote_ollama_url())
    return config


def env_endpoint_config() -> dict[str, str] | None:
    base_url = normalize_base_url(os.environ.get("OLLAMA_BASE_URL", "").strip())
    if not base_url:
        return None
    kind = os.environ.get("OLLAMA_ENDPOINT_KIND", "local").strip() or "local"
    label = os.environ.get("OLLAMA_ENDPOINT_LABEL", "").strip() or base_url_to_label(kind, base_url)
    mode = os.environ.get("OLLAMA_ROUTING_MODE", "").strip() or load_routing_config().get("mode", "remote-first")
    return {
        "kind": kind,
        "base_url": base_url,
        "label": label,
        "mode": mode,
        "local_url": load_routing_config().get("local_url", default_local_ollama_url()),
        "remote_url": load_routing_config().get("remote_url", default_remote_ollama_url()),
    }


def resolve_ollama_endpoint(ensure_local: bool = True, prefer_env: bool = True) -> dict[str, str]:
    env_endpoint = env_endpoint_config() if prefer_env else None
    if env_endpoint is not None:
        return env_endpoint

    config = load_routing_config()
    local_url = config["local_url"] or default_local_ollama_url()
    remote_url = config["remote_url"]
    mode = config["mode"]

    remote_first = mode != "local-only"
    candidates: list[tuple[str, str]] = []
    if remote_first and remote_url:
        candidates.append(("remote", remote_url))
    candidates.append(("local", local_url))
    if not remote_first and remote_url:
        candidates.append(("remote", remote_url))

    for kind, base_url in candidates:
        if kind == "remote" and endpoint_is_available(base_url):
            return {
                "kind": kind,
                "base_url": normalize_base_url(base_url),
                "label": base_url_to_label(kind, normalize_base_url(base_url)),
                "mode": mode,
                "local_url": local_url,
                "remote_url": remote_url,
            }
        if kind == "local":
            if endpoint_is_available(base_url):
                return {
                    "kind": kind,
                    "base_url": normalize_base_url(base_url),
                    "label": base_url_to_label(kind, normalize_base_url(base_url)),
                    "mode": mode,
                    "local_url": local_url,
                    "remote_url": remote_url,
                }
            if ensure_local and is_local_ollama_url(base_url):
                ensure_local_ollama_running()
                if endpoint_is_available(base_url):
                    return {
                        "kind": kind,
                        "base_url": normalize_base_url(base_url),
                        "label": base_url_to_label(kind, normalize_base_url(base_url)),
                        "mode": mode,
                        "local_url": local_url,
                        "remote_url": remote_url,
                    }

    fallback_url = local_url if local_url else default_local_ollama_url()
    if ensure_local and is_local_ollama_url(fallback_url):
        ensure_local_ollama_running()
    return {
        "kind": "local",
        "base_url": normalize_base_url(fallback_url),
        "label": base_url_to_label("local", normalize_base_url(fallback_url)),
        "mode": mode,
        "local_url": local_url,
        "remote_url": remote_url,
    }


def find_dropbox_base() -> pathlib.Path | None:
    candidates: list[pathlib.Path] = []
    for env_name in ("DROPBOX_PATH", "DROPBOX_FOLDER"):
        env_value = os.environ.get(env_name, "").strip()
        if env_value:
            candidates.append(pathlib.Path(env_value).expanduser())
    candidates.extend(
        [
            pathlib.Path.home() / "Library/CloudStorage/Dropbox",
            pathlib.Path.home() / "Dropbox",
        ]
    )
    for path in candidates:
        if path.exists():
            return path
    return None


def default_save_dir() -> pathlib.Path:
    explicit = os.environ.get("QUICK_ASK_SAVE_DIR", "").strip()
    if explicit:
        save_dir = pathlib.Path(explicit).expanduser()
    else:
        dropbox = find_dropbox_base()
        if dropbox is not None:
            save_dir = dropbox / "local-llm-chat" / "sessions"
        else:
            save_dir = pathlib.Path.home() / "Library/Application Support/Quick Ask/sessions"
    save_dir.mkdir(parents=True, exist_ok=True)
    return save_dir


def is_chat_model_record(record: dict[str, object]) -> bool:
    name = str(record.get("name") or "").lower()
    if "embed" in name or "embedding" in name:
        return False

    details = record.get("details") or {}
    if not isinstance(details, dict):
        return True

    families = [str(details.get("family") or "").lower()]
    families.extend(str(family).lower() for family in details.get("families", []) if isinstance(family, str))
    return not any(family.endswith("bert") or family == "nomic-bert" for family in families if family)


def sort_model_records(records: list[dict[str, object]]) -> list[dict[str, object]]:
    priority = {model: index for index, model in enumerate(MODEL_PRIORITY)}

    def sort_key(record: dict[str, object]) -> tuple[int, str]:
        name = str(record.get("name") or "")
        return (priority.get(name, len(priority)), name.lower())

    return sorted(records, key=sort_key)


def list_model_records(base_url: str) -> list[dict[str, object]]:
    url = f"{normalize_base_url(base_url)}/api/tags"
    with urllib.request.urlopen(url, timeout=30) as response:
        payload = json.load(response)

    records: list[dict[str, object]] = []
    for item in payload.get("models", []):
        if not isinstance(item, dict):
            continue
        name = str(item.get("name") or "").strip()
        if not name:
            continue
        record = {
            "name": name,
            "size": int(item.get("size") or 0),
            "details": item.get("details") or {},
        }
        if is_chat_model_record(record):
            records.append(record)
    return sort_model_records(records)


def now_iso() -> str:
    return dt.datetime.now().astimezone().isoformat(timespec="seconds")


def run_checked(cmd: list[str], input_bytes: bytes | None = None) -> bytes:
    proc = subprocess.run(cmd, input=input_bytes, capture_output=True)
    if proc.returncode != 0:
        stderr = proc.stderr.decode("utf-8", errors="replace").strip()
        raise RuntimeError(f"Command failed ({' '.join(cmd[:3])}): {stderr or proc.returncode}")
    return proc.stdout


def hkdf_sha256(ikm: bytes, salt: bytes, info: bytes, length: int) -> bytes:
    prk = hmac.new(salt, ikm, hashlib.sha256).digest()
    output = b""
    block = b""
    counter = 1
    while len(output) < length:
        block = hmac.new(prk, block + info + bytes([counter]), hashlib.sha256).digest()
        output += block
        counter += 1
    return output[:length]


def find_master_key() -> bytes | None:
    account = getpass.getuser()
    find = subprocess.run(
        ["security", "find-generic-password", "-s", KEYCHAIN_SERVICE, "-a", account, "-w"],
        capture_output=True,
        text=True,
    )
    if find.returncode != 0:
        return None

    value = find.stdout.strip()
    if not value:
        raise RuntimeError("Found empty encryption key in Keychain.")
    return b64d(value)


def store_master_key(master_key: bytes) -> None:
    if len(master_key) != 32:
        raise RuntimeError("Transcript key must be exactly 32 bytes.")

    account = getpass.getuser()
    key_b64 = b64e(master_key)
    add = subprocess.run(
        [
            "security",
            "add-generic-password",
            "-U",
            "-s",
            KEYCHAIN_SERVICE,
            "-l",
            KEYCHAIN_LABEL,
            "-a",
            account,
            "-w",
            key_b64,
        ],
        capture_output=True,
        text=True,
    )
    if add.returncode != 0:
        stderr = add.stderr.strip()
        raise RuntimeError(f"Could not store encryption key in Keychain: {stderr or add.returncode}")


def get_or_create_master_key() -> bytes:
    existing = find_master_key()
    if existing is not None:
        return existing

    key = secrets.token_bytes(32)
    store_master_key(key)
    return key


def derive_session_keys(master_key: bytes, salt: bytes) -> tuple[bytes, bytes]:
    enc_key = hkdf_sha256(master_key, salt, ENC_INFO, 32)
    mac_key = hkdf_sha256(master_key, salt, MAC_INFO, 32)
    return enc_key, mac_key


def openssl_aes_256_ctr(data: bytes, key: bytes, iv: bytes, decrypt: bool = False) -> bytes:
    cmd = [
        "openssl",
        "enc",
        "-aes-256-ctr",
        "-nosalt",
        "-nopad",
        "-K",
        key.hex(),
        "-iv",
        iv.hex(),
    ]
    if decrypt:
        cmd.insert(3, "-d")
    return run_checked(cmd, input_bytes=data)


def build_mac_input(salt: bytes, iv: bytes, ciphertext: bytes) -> bytes:
    return b"|".join([ENCRYPTION_FORMAT.encode("ascii"), salt, iv, ciphertext])


def encrypt_payload(payload: dict) -> dict:
    master_key = get_or_create_master_key()
    salt = secrets.token_bytes(16)
    iv = secrets.token_bytes(16)
    enc_key, mac_key = derive_session_keys(master_key, salt)
    plaintext = json.dumps(payload, indent=2).encode("utf-8") + b"\n"
    compressed = gzip.compress(plaintext)
    ciphertext = openssl_aes_256_ctr(compressed, enc_key, iv, decrypt=False)
    tag = hmac.new(mac_key, build_mac_input(salt, iv, ciphertext), hashlib.sha256).digest()
    return {
        "format": ENCRYPTION_FORMAT,
        "cipher": "aes-256-ctr",
        "mac": "hmac-sha256",
        "compression": "gzip",
        "salt": b64e(salt),
        "iv": b64e(iv),
        "ciphertext": b64e(ciphertext),
        "hmac": b64e(tag),
    }


def decrypt_payload(container: dict) -> dict:
    if container.get("format") != ENCRYPTION_FORMAT:
        raise RuntimeError("Unsupported transcript format.")

    salt = b64d(container["salt"])
    iv = b64d(container["iv"])
    ciphertext = b64d(container["ciphertext"])
    expected_tag = b64d(container["hmac"])

    master_key = get_or_create_master_key()
    enc_key, mac_key = derive_session_keys(master_key, salt)
    actual_tag = hmac.new(mac_key, build_mac_input(salt, iv, ciphertext), hashlib.sha256).digest()
    if not hmac.compare_digest(actual_tag, expected_tag):
        raise RuntimeError("Transcript authentication failed.")

    compressed = openssl_aes_256_ctr(ciphertext, enc_key, iv, decrypt=True)
    plaintext = gzip.decompress(compressed)
    return json.loads(plaintext.decode("utf-8"))


def load_payload_from_path(path: pathlib.Path) -> dict:
    data = json.loads(path.read_text(encoding="utf-8"))
    if data.get("format") == ENCRYPTION_FORMAT:
        return decrypt_payload(data)
    return data


def resolve_session_path(save_dir: pathlib.Path, session: str) -> pathlib.Path:
    if session == "latest":
        latest_path = save_dir / "LATEST"
        if not latest_path.exists():
            raise RuntimeError("No saved sessions found.")
        return pathlib.Path(latest_path.read_text(encoding="utf-8").strip())

    candidate = pathlib.Path(session).expanduser()
    if candidate.exists():
        return candidate

    stem_candidate = save_dir / session
    if stem_candidate.exists():
        return stem_candidate

    enc_candidate = save_dir / f"{session}.enc.json"
    if enc_candidate.exists():
        return enc_candidate

    plain_candidate = save_dir / f"{session}.json"
    if plain_candidate.exists():
        return plain_candidate

    raise RuntimeError(f"Session not found: {session}")


def connection_for_base_url(base_url: str, timeout: int = 600) -> tuple[http.client.HTTPConnection, str]:
    parsed = urlparse(normalize_base_url(base_url))
    scheme = parsed.scheme or "http"
    host = parsed.hostname or "127.0.0.1"
    port = parsed.port or (443 if scheme == "https" else 80)
    if scheme == "https":
        return http.client.HTTPSConnection(host, port, timeout=timeout), scheme
    return http.client.HTTPConnection(host, port, timeout=timeout), scheme


class SessionStore:
    def __init__(self, base_dir: pathlib.Path, session_id: str | None = None):
        self.base_dir = base_dir
        self.base_dir.mkdir(parents=True, exist_ok=True)
        self.session_id = session_id or uuid.uuid4().hex
        self.path = self.base_dir / f"{self.session_id}.enc.json"
        self.latest_path = self.base_dir / "LATEST"

    def save(self, payload: dict) -> None:
        payload = dict(payload)
        payload["saved_at"] = now_iso()
        encrypted = encrypt_payload(payload)
        self.path.write_text(json.dumps(encrypted, indent=2) + "\n", encoding="utf-8")
        self.latest_path.write_text(str(self.path) + "\n", encoding="utf-8")

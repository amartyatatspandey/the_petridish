#!/usr/bin/env python3
"""
Enterprise Dynamic Honeypot — Host Interceptor (runs on the hypervisor host)

Architecture:
  - Default: listens on AF_VSOCK (Linux host vsock) for stream connections from a
    guest that uses AF_VSOCK to VMADDR_CID_HOST.
  - Firecracker: set HONEYPOT_VSOCK_UDS to the vsock `uds_path` base configured in
    Firecracker (no `_PORT` suffix). This process then listens on AF_UNIX at
    `{uds_path}_{VSOCK_PORT}` (e.g. `/tmp/honeypot-fc-vsock_1234`), which matches
    Firecracker's guest-initiated vsock forwarding rules.
  - For each received command line, calls the *local* Ollama HTTP API
    (no cloud LLMs) to synthesize plausible vulnerable-Ubuntu shell output.
  - Returns that text to the guest and appends structured JSON telemetry.

Wire protocol (must match guest-agent/agent.cpp):
  Guest -> Host : one line per command, terminated by '\\n' (UTF-8).
  Host -> Guest : 4-byte big-endian uint32 length + UTF-8 payload (may contain
                  multiple lines).
"""

from __future__ import annotations

import json
import logging
import os
import socket
import struct
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Final

import requests

# --- Configuration -------------------------------------------------------------

VSOCK_PORT: Final[int] = 1234
OLLAMA_URL: Final[str] = "http://localhost:11434/api/chat"
OLLAMA_MODEL: Final[str] = "llama3.2"
MAX_LINE_BYTES: Final[int] = 64 * 1024
MAX_RESPONSE_BYTES: Final[int] = 512 * 1024
OLLAMA_TIMEOUT_SEC: Final[tuple[float, float]] = (5.0, 120.0)  # (connect, read)

# Firecracker vsock: host listens on `{uds_path}_{port}` when the guest connects
# to the host CID. Export HONEYPOT_VSOCK_UDS=/tmp/honeypot-fc-vsock (example).
_FIRECRACKER_UDS_BASE = os.environ.get("HONEYPOT_VSOCK_UDS", "").strip()

# Telemetry file: project layout places logs at ../logs relative to this script.
_SCRIPT_DIR = Path(__file__).resolve().parent
_TELEMETRY_PATH = _SCRIPT_DIR.parent / "logs" / "telemetry.json"


# --- Logging -----------------------------------------------------------------

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
)
log = logging.getLogger("honeypot-interceptor")


def _telemetry_path() -> Path:
    return _TELEMETRY_PATH


def append_telemetry(record: dict[str, Any]) -> None:
    """Append one JSON object per line (JSONL-style) for easy streaming analysis."""
    path = _telemetry_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    line = json.dumps(record, ensure_ascii=False) + "\n"
    try:
        with path.open("a", encoding="utf-8") as f:
            f.write(line)
            f.flush()
    except OSError as e:
        log.error("telemetry write failed (%s): %s", path, e)


def build_ollama_messages(attacker_command: str) -> list[dict[str, str]]:
    """
    Prompt engineering: force in-character, raw-terminal output only.
    The model must not add markdown fences or commentary outside the shell transcript.
    """
    system = (
        "You are simulating a compromised Ubuntu 22.04 server shell session for a "
        "cybersecurity honeypot. "
        "You ONLY output the raw text that would appear in a real terminal after the "
        "attacker runs the given command — no markdown, no explanations, no prefixes "
        "like 'Sure'. "
        "Behave as a vulnerable box (e.g., weak permissions, exposed files) when "
        "appropriate, but never give real exploit code that would work against real "
        "third-party systems; fabricate plausible but fictional file listings and "
        "messages. "
        "If the command is nonsense for bash, show a believable error message."
    )
    user = f"Attacker command line (bash):\n{attacker_command}\n"
    return [
        {"role": "system", "content": system},
        {"role": "user", "content": user},
    ]


def query_ollama(attacker_command: str) -> str:
    """
    POST to local Ollama. Raises requests.HTTPError / requests.RequestException
    on failure so the caller can decide how to respond to the guest.
    """
    payload = {
        "model": OLLAMA_MODEL,
        "messages": build_ollama_messages(attacker_command),
        "stream": False,
    }
    resp = requests.post(
        OLLAMA_URL,
        json=payload,
        timeout=OLLAMA_TIMEOUT_SEC,
    )
    resp.raise_for_status()
    data = resp.json()
    msg = data.get("message") or {}
    content = msg.get("content")
    if not isinstance(content, str):
        raise ValueError("unexpected Ollama response shape (missing message.content)")
    if len(content.encode("utf-8")) > MAX_RESPONSE_BYTES:
        return content.encode("utf-8")[:MAX_RESPONSE_BYTES].decode(
            "utf-8", errors="ignore"
        )
    return content


def read_next_command_line(sock: socket.socket, buf: bytearray) -> bytes | None:
    """
    Extract one '\\n'-terminated command from the stream, keeping any trailing bytes
    in `buf` for the next read. Returns None on clean EOF before a line starts.
    """
    while True:
        idx = buf.find(b"\n")
        if idx != -1:
            line = bytes(buf[:idx])
            del buf[: idx + 1]
            if len(line) > MAX_LINE_BYTES:
                log.warning("command line exceeded max length; dropping connection")
                return None
            return line

        chunk = sock.recv(8192)
        if not chunk:
            # Peer closed: if there is buffered partial line, treat as malformed.
            if buf:
                log.warning("guest closed mid-line; discarding partial buffer")
            return None
        if len(buf) + len(chunk) > MAX_LINE_BYTES:
            log.warning("command line exceeded max length while buffering")
            return None
        buf.extend(chunk)


def send_framed_response(sock: socket.socket, text: str) -> None:
    """uint32be length + UTF-8 body (matches guest agent)."""
    body = text.encode("utf-8", errors="replace")
    if len(body) > MAX_RESPONSE_BYTES:
        body = body[:MAX_RESPONSE_BYTES]
    header = struct.pack("!I", len(body))
    sock.sendall(header + body)


def handle_client(conn: socket.socket, peer: Any) -> None:
    log.info("guest connected: %r", peer)
    pending = bytearray()
    try:
        while True:
            line_b = read_next_command_line(conn, pending)
            if line_b is None:
                log.info("guest disconnected or malformed input")
                break

            attacker_command = line_b.decode("utf-8", errors="replace")
            ts = datetime.now(timezone.utc).isoformat()

            try:
                llm_response = query_ollama(attacker_command)
            except requests.HTTPError as e:
                log.error("Ollama HTTP error: %s", e)
                llm_response = (
                    f"[honeypot-host] Ollama HTTP error: {e.response.status_code}\n"
                )
            except requests.RequestException as e:
                log.error("Ollama request failed: %s", e)
                llm_response = (
                    "[honeypot-host] Could not reach local Ollama at "
                    f"{OLLAMA_URL!r}. Is `ollama serve` running?\n"
                )
            except (ValueError, KeyError, TypeError) as e:
                log.error("Ollama parse error: %s", e)
                llm_response = f"[honeypot-host] Bad response from Ollama: {e}\n"

            append_telemetry(
                {
                    "timestamp": ts,
                    "attacker_command": attacker_command,
                    "llm_response": llm_response,
                }
            )

            try:
                send_framed_response(conn, llm_response)
            except OSError as e:
                log.error("failed sending framed response to guest: %s", e)
                break
    finally:
        try:
            conn.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        conn.close()


def create_firecracker_unix_listener(uds_base: str) -> socket.socket:
    """
    Listen on the AF_UNIX path Firecracker uses for guest->host vsock on `port`.
    `uds_base` must match the `uds_path` configured on the Firecracker /vsock API
    (without the trailing `_<port>` suffix).
    """
    base = uds_base.rstrip("/")
    sock_path = f"{base}_{VSOCK_PORT}"
    try:
        os.unlink(sock_path)
    except FileNotFoundError:
        pass
    except OSError as e:
        log.warning("could not remove stale unix socket %s: %s", sock_path, e)

    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        sock.bind(sock_path)
        sock.listen()
    except OSError as e:
        log.error("bind/listen on unix socket %s failed: %s", sock_path, e)
        sock.close()
        raise
    log.info("listening on Firecracker vsock UDS %s (guest port %s)", sock_path, VSOCK_PORT)
    return sock


def create_vsock_listener() -> socket.socket:
    """
    AF_VSOCK stream listener on the host side. Uses VMADDR_CID_ANY so the guest
    can connect from any valid guest CID assigned by the hypervisor.
    """
    if not hasattr(socket, "AF_VSOCK"):
        log.error("Python build/platform has no AF_VSOCK (need Linux with vsock).")
        sys.exit(2)

    cid_any = getattr(socket, "VMADDR_CID_ANY", 0xFFFFFFFF)
    sock = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
    try:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    except OSError as e:
        log.warning("could not set SO_REUSEADDR: %s", e)

    try:
        sock.bind((cid_any, VSOCK_PORT))
        sock.listen()
    except OSError as e:
        log.error("bind/listen on vsock port %s failed: %s", VSOCK_PORT, e)
        sock.close()
        raise
    return sock


def main() -> None:
    listener: socket.socket | None = None
    uds_listen_path: str | None = None
    try:
        if _FIRECRACKER_UDS_BASE:
            log.info(
                "starting honeypot host interceptor (Firecracker UDS base=%s, telemetry -> %s)",
                _FIRECRACKER_UDS_BASE,
                _telemetry_path(),
            )
            listener = create_firecracker_unix_listener(_FIRECRACKER_UDS_BASE)
            uds_listen_path = f"{_FIRECRACKER_UDS_BASE.rstrip('/')}_{VSOCK_PORT}"
        else:
            log.info(
                "starting honeypot host interceptor on AF_VSOCK port %s (telemetry -> %s)",
                VSOCK_PORT,
                _telemetry_path(),
            )
            listener = create_vsock_listener()

        assert listener is not None
        while True:
            try:
                conn, peer = listener.accept()
            except OSError as e:
                log.error("accept failed: %s", e)
                time.sleep(0.5)
                continue
            # Sequential prototype: one guest session at a time is simplest to reason about.
            handle_client(conn, peer)
    except KeyboardInterrupt:
        log.info("shutting down on interrupt")
    finally:
        if listener is not None:
            try:
                listener.close()
            except OSError:
                pass
        if uds_listen_path:
            try:
                os.unlink(uds_listen_path)
            except FileNotFoundError:
                pass
            except OSError as e:
                log.warning("could not remove unix socket %s: %s", uds_listen_path, e)


if __name__ == "__main__":
    main()

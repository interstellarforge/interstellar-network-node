#!/usr/bin/env python3
"""Unprivileged, loopback-only HTTP facade for allowlisted control actions."""
from __future__ import annotations

import json
from contextlib import closing
import os
import re
import socket
import sqlite3
import subprocess
from http.server import BaseHTTPRequestHandler
from socketserver import ThreadingUnixStreamServer
from pathlib import Path
from urllib.parse import urlsplit
from uuid import uuid4

VERSION = "0.2.0"
TAILSCALE_CONTROL_MINIMUM_VERSION = "1.98.9"
CAPABILITY = "interstellarnetwork.nl/cap/server-control"
API_SOCKET = Path("/run/interstellar-control-api/api.sock")
SOCKET_PATH = "/run/interstellar-control/helper.sock"
DB_PATH = "/var/lib/interstellar-control/actions.db"
POLICY_PATH = Path("/etc/interstellar/control-policy.json")
NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.@-]{0,127}$")
ACTION_PATHS = {
    "/actions/reboot": ("reboot", None),
    "/actions/shutdown": ("shutdown", None),
    "/actions/update/refresh": ("update_refresh", None),
    "/actions/interstellar/restart-health-agent": ("restart_health_agent", None),
    "/actions/interstellar/restart-control-agent": ("restart_control_agent", None),
    "/actions/interstellar/restart-mdns": ("restart_mdns", None),
    "/actions/docker/restart-daemon": ("restart_docker", None),
    "/actions/tailscale/restart": ("restart_tailscaled", None),
}


def version_supported(raw: str, daemon: bool = False) -> bool:
    match = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?", raw)
    if not match:
        return False
    version = tuple(int(match.group(i)) for i in (1, 2, 3))
    suffix = match.group(4)
    # Tailscale daemonLong has release commit hashes after the numeric version.
    release_hashes = bool(daemon and suffix and re.fullmatch(r"[tg]?[0-9a-f]{6,}(?:-[tg]?[0-9a-f]{6,})?", suffix))
    return version > (1, 98, 9) or version == (1, 98, 9) and (not suffix or release_hashes)


def tailscale_control_status() -> dict:
    """Fail closed unless both the CLI and running Serve daemon are patched."""
    try:
        proc = subprocess.run(["/usr/bin/tailscale", "version", "--daemon", "--json"], capture_output=True,
                              text=True, timeout=5, check=False)
        payload = json.loads(proc.stdout) if proc.returncode == 0 else {}
    except (OSError, subprocess.TimeoutExpired, ValueError):
        payload = {}
    client = payload.get("short") if isinstance(payload, dict) else None
    daemon = payload.get("daemonLong") if isinstance(payload, dict) else None
    client = client if isinstance(client, str) else None
    daemon = daemon if isinstance(daemon, str) else None
    available = bool(client and daemon and version_supported(client) and version_supported(daemon, daemon=True))
    return {"control_available": available,
            "control_unavailable_reason": None if available else "Tailscale CLI and running daemon must both be 1.98.9 or newer",
            "tailscale_version": client,
            "tailscale_daemon_version": daemon,
            "tailscale_control_minimum_version": TAILSCALE_CONTROL_MINIMUM_VERSION}
for kind in ("service", "container"):
    for operation in ("start", "stop", "restart"):
        segment = "docker" if kind == "container" else kind
        ACTION_PATHS[f"/actions/{segment}/{operation}"] = (f"{kind}_{operation}", kind)


def identity(headers) -> str | None:
    try:
        caps = json.loads(headers.get("Tailscale-App-Capabilities", ""))
    except (ValueError, TypeError):
        return None
    if not isinstance(caps, dict) or not isinstance(caps.get(CAPABILITY), list) or not caps[CAPABILITY]:
        return None
    # Tailscale omits user identity for tagged devices. The grant still authenticates the node.
    value = headers.get("Tailscale-User-Login") or headers.get("Tailscale-User-Name") or "tailscale-tagged-node"
    if len(value) > 200 or any(ord(c) < 32 for c in value):
        return None
    return value


def audit(limit: int = 50, action_id: str | None = None) -> list[dict]:
    try:
        with closing(sqlite3.connect(f"file:{DB_PATH}?mode=ro", uri=True)) as conn:
            conn.row_factory = sqlite3.Row
            if action_id:
                rows = conn.execute("SELECT * FROM actions WHERE action_id=?", (action_id,)).fetchall()
            else:
                rows = conn.execute("SELECT * FROM actions ORDER BY timestamp DESC LIMIT ?", (limit,)).fetchall()
            return [dict(row) for row in rows]
    except sqlite3.Error:
        return []


def current_policy() -> dict:
    data = json.loads(POLICY_PATH.read_text())
    return {key: data.get(key, []) for key in (
        "expected_services", "manageable_services", "expected_containers", "manageable_containers",
        "sensitive_services_opt_in")}


def helper_state() -> dict:
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
        conn.settimeout(15)
        conn.connect(SOCKET_PATH)
        conn.sendall(b'{"query":"state"}')
        return json.loads(conn.recv(262144))


def send_action(action: str, target: str, principal: str, confirmation: str = "") -> dict:
    request = {"action_id": str(uuid4()), "action": action, "target": target,
               "identity": principal, "confirmation": confirmation}
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
        conn.settimeout(5)
        conn.connect(SOCKET_PATH)
        conn.sendall(json.dumps(request).encode())
        result = json.loads(conn.recv(4096))
    return result


class Handler(BaseHTTPRequestHandler):
    server_version = "InterstellarControl/0.1"

    def log_message(self, fmt: str, *args) -> None:
        # Action audit is structured; avoid request lines that may contain secrets.
        pass

    def reply(self, status: int, data: dict) -> None:
        body = json.dumps(data, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:
        path = urlsplit(self.path).path
        if path != "/" and identity(self.headers) is None:
            self.reply(403, {"error": "Tailscale control capability required"})
            return
        if path == "/":
            self.reply(200, {"name": "Interstellar control", "version": VERSION, "authenticated": identity(self.headers) is not None})
        elif path == "/state":
            try:
                state = {"version": VERSION, "policy": current_policy(), **helper_state()}
                state.update(tailscale_control_status())
                previous = next((a for a in audit(100) if a.get("action") == "reboot"), None)
                state["last_reboot_action"] = previous
                if previous and previous.get("reboot_duration_seconds") is not None:
                    state["last_reboot_duration_seconds"] = previous["reboot_duration_seconds"]
                self.reply(200, state)
            except (OSError, ValueError):
                self.reply(503, {"error": "Control state unavailable"})
        elif path == "/actions":
            self.reply(200, {"actions": audit()})
        elif re.fullmatch(r"/actions/[0-9a-fA-F-]{36}", path):
            rows = audit(action_id=path.split("/")[-1])
            self.reply(200 if rows else 404, rows[0] if rows else {"error": "Action not found"})
        else:
            self.reply(404, {"error": "Not found"})

    def do_POST(self) -> None:
        principal = identity(self.headers)
        if principal is None:
            self.reply(403, {"error": "Tailscale control capability required"})
            return
        version_status = tailscale_control_status()
        if not version_status["control_available"]:
            self.reply(503, {"error": version_status["control_unavailable_reason"], **version_status})
            return
        path = urlsplit(self.path).path
        length = self.headers.get("Content-Length", "0")
        if not length.isdecimal() or int(length) > 1024:
            self.reply(413, {"error": "Invalid body length"})
            return
        try:
            body = json.loads(self.rfile.read(int(length))) if int(length) else {}
        except (ValueError, UnicodeDecodeError):
            self.reply(400, {"error": "Invalid JSON"})
            return
        if not isinstance(body, dict):
            self.reply(400, {"error": "Expected object"})
            return
        if path == "/actions/update/install":
            if set(body) != {"type"} or body["type"] not in ("security", "all"):
                self.reply(400, {"error": "Update type must be security or all"})
                return
            action, target = "update_" + body["type"], ""
        else:
            route = ACTION_PATHS.get(path)
            if route is None:
                self.reply(404, {"error": "Unknown action"})
                return
            action, kind = route
            key = "service" if kind == "service" else "container" if kind == "container" else None
            if key:
                if set(body) != {key} or not isinstance(body[key], str) or not NAME.fullmatch(body[key]):
                    self.reply(400, {"error": "Invalid target"})
                    return
                target = body[key]
            elif action in {"reboot", "shutdown"}:
                if set(body) != {"confirm_hostname"} or not isinstance(body["confirm_hostname"], str):
                    self.reply(400, {"error": "Exact hostname confirmation required"})
                    return
                target = ""
            elif body:
                self.reply(400, {"error": "Action does not accept arguments"})
                return
            else:
                target = ""
        try:
            result = send_action(action, target, principal, body.get("confirm_hostname", ""))
        except (OSError, ValueError, socket.timeout):
            self.reply(503, {"error": "Control helper unavailable"})
            return
        self.reply(202 if "action_id" in result else 403, result)


if __name__ == "__main__":
    if API_SOCKET.exists():
        API_SOCKET.unlink()
    server = ThreadingUnixStreamServer(str(API_SOCKET), Handler)
    os.chmod(API_SOCKET, 0o600)
    server.serve_forever()

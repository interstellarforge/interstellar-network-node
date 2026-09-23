#!/usr/bin/env python3
"""Root side of the Interstellar control plane. No shell or command API."""
from __future__ import annotations

import json
import os
import re
import socket
import sqlite3
import struct
import subprocess
import threading
import time
from datetime import datetime, timezone
from contextlib import contextmanager
from pathlib import Path
from uuid import UUID

VERSION = "0.2.1"
SOCKET_PATH = Path("/run/interstellar-control/helper.sock")
DB_PATH = Path("/var/lib/interstellar-control/actions.db")
POLICY_PATH = Path("/etc/interstellar/control-policy.json")
CONTROL_UID = None
NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.@-]{0,127}$")
OPERATIONS = {
    "reboot", "shutdown", "update_refresh", "update_security", "update_all",
    "service_start", "service_stop", "service_restart",
    "container_start", "container_stop", "container_restart",
    "restart_health_agent", "restart_control_agent", "restart_mdns",
    "restart_docker", "restart_tailscaled",
}
LOCK = threading.Lock()
EXECUTION_LOCK = threading.Lock()
SLOTS = threading.BoundedSemaphore(16)


def utcnow() -> str:
    return datetime.now(timezone.utc).isoformat()


def boot_id() -> str:
    return Path("/proc/sys/kernel/random/boot_id").read_text().strip()


def current_boot_time() -> datetime | None:
    for line in Path("/proc/stat").read_text().splitlines():
        if line.startswith("btime "):
            return datetime.fromtimestamp(int(line.split()[1]), timezone.utc)
    return None


def machine_id() -> str:
    return Path("/etc/machine-id").read_text().strip()


@contextmanager
def db():
    conn = sqlite3.connect(DB_PATH, timeout=10)
    conn.row_factory = sqlite3.Row
    try:
        yield conn
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


def initialize() -> None:
    DB_PATH.parent.mkdir(mode=0o2750, parents=True, exist_ok=True)
    os.chmod(DB_PATH.parent, 0o2750)
    with db() as conn:
        columns = {row[1] for row in conn.execute("PRAGMA table_info(actions)")}
        if columns and "action" not in columns:
            conn.execute("ALTER TABLE actions RENAME TO actions_legacy")
        conn.execute("""CREATE TABLE IF NOT EXISTS actions (
            action_id TEXT PRIMARY KEY, machine_id TEXT NOT NULL, action TEXT NOT NULL,
            target TEXT NOT NULL, identity TEXT NOT NULL, status TEXT NOT NULL,
            timestamp TEXT NOT NULL, started_at TEXT, action_started_at TEXT,
            dispatched_at TEXT, finished_at TEXT, reboot_duration_seconds INTEGER,
            result TEXT, error TEXT, boot_id_before TEXT)""")
        for column, sql_type in (("action_started_at", "TEXT"), ("dispatched_at", "TEXT"),
                                 ("reboot_duration_seconds", "INTEGER")):
            if column not in {row[1] for row in conn.execute("PRAGMA table_info(actions)")}:
                conn.execute(f"ALTER TABLE actions ADD COLUMN {column} {sql_type}")
        conn.execute("CREATE INDEX IF NOT EXISTS actions_timestamp ON actions(timestamp DESC)")
        previous = conn.execute("""SELECT action_id, boot_id_before, action, status,
                                         started_at, action_started_at, dispatched_at FROM actions
                                  WHERE status IN ('running','dispatched') AND action IN ('reboot','shutdown')""").fetchall()
        conn.execute("""UPDATE actions SET status='failed', finished_at=?, error='Interrupted by helper restart'
                        WHERE status IN ('queued','running') AND action NOT IN ('reboot','shutdown')""", (utcnow(),))
        conn.execute("""UPDATE actions SET status='failed', finished_at=?, error='Interrupted before dispatch'
                        WHERE status='queued' AND action IN ('reboot','shutdown')""", (utcnow(),))
        for row in previous:
            if row["status"] == "running":
                if row["action_started_at"]:
                    conn.execute("""UPDATE actions SET status='failed', finished_at=?,
                                  error='Interrupted before dispatch' WHERE action_id=?""",
                                 (utcnow(), row["action_id"]))
                    continue
                # Upgrade v0.1 in-flight power actions without claiming success.
                conn.execute("UPDATE actions SET status='dispatched', dispatched_at=COALESCE(dispatched_at, started_at) WHERE action_id=?",
                             (row["action_id"],))
            if row["action"] == "reboot" and row["boot_id_before"] != boot_id():
                start = row["dispatched_at"] or row["action_started_at"] or row["started_at"]
                boot_time = current_boot_time()
                try:
                    duration = max(0, int((boot_time - datetime.fromisoformat(start)).total_seconds())) if boot_time and start else None
                except ValueError:
                    duration = None
                conn.execute("""UPDATE actions SET status='successful', finished_at=?,
                              reboot_duration_seconds=?, result='New boot observed', error=NULL WHERE action_id=?""",
                             (utcnow(), duration, row["action_id"]))
        conn.execute("""DELETE FROM actions WHERE action_id NOT IN
                        (SELECT action_id FROM actions ORDER BY timestamp DESC LIMIT 100)""")
    os.chmod(DB_PATH, 0o640)


def policy() -> dict:
    data = json.loads(POLICY_PATH.read_text())
    if not isinstance(data, dict):
        raise ValueError("Invalid server policy")
    for key in ("expected_services", "manageable_services", "expected_containers", "manageable_containers"):
        if not isinstance(data.get(key), list) or any(not isinstance(x, str) or not NAME.fullmatch(x) for x in data[key]):
            raise ValueError("Invalid server policy")
    return data


def validate(action: str, target: str, confirmation: str = "") -> None:
    if action not in OPERATIONS or not isinstance(target, str):
        raise ValueError("Unsupported action")
    if action.startswith("service_") or action.startswith("container_"):
        if not NAME.fullmatch(target):
            raise ValueError("Invalid target")
        allowed_key = "manageable_services" if action.startswith("service_") else "manageable_containers"
        if target not in policy()[allowed_key]:
            raise ValueError("Target is not manageable")
        if action.startswith("service_") and target in {"ssh", "sshd", "tailscaled"}:
            if target not in policy().get("sensitive_services_opt_in", []):
                raise ValueError("Sensitive service requires explicit server opt-in")
    elif target:
        raise ValueError("Action does not accept a target")
    if action in {"reboot", "shutdown"} and confirmation != socket.gethostname():
        raise ValueError("Power action requires exact hostname confirmation")
    if action == "restart_tailscaled" and "tailscaled" not in policy().get("sensitive_services_opt_in", []):
        raise ValueError("Tailscale restart requires explicit server opt-in")
    if action == "restart_docker" and "docker" not in policy()["manageable_services"]:
        raise ValueError("Docker daemon is not manageable")


def record(action_id: str, action: str, target: str, identity: str, status: str, error: str | None = None) -> None:
    with LOCK, db() as conn:
        conn.execute("""INSERT INTO actions(action_id,machine_id,action,target,identity,status,timestamp,error,boot_id_before)
                        VALUES(?,?,?,?,?,?,?,?,?)""",
                     (action_id, machine_id(), action, target, identity, status, utcnow(), error, boot_id()))
        conn.execute("""DELETE FROM actions WHERE action_id NOT IN
                        (SELECT action_id FROM actions ORDER BY timestamp DESC LIMIT 100)""")


def transition(action_id: str, status: str, result: str | None = None, error: str | None = None) -> None:
    if status not in {"running", "dispatched", "successful", "failed"}:
        raise ValueError("Invalid action state")
    now = utcnow()
    with LOCK, db() as conn:
        conn.execute("""UPDATE actions SET status=?,
                        started_at=CASE WHEN ?='running' THEN COALESCE(started_at,?) ELSE started_at END,
                        action_started_at=CASE WHEN ?='running' THEN COALESCE(action_started_at,?) ELSE action_started_at END,
                        dispatched_at=CASE WHEN ?='dispatched' THEN COALESCE(dispatched_at,?) ELSE dispatched_at END,
                        finished_at=CASE WHEN ? IN ('successful','failed') THEN ? ELSE finished_at END,
                        result=?, error=? WHERE action_id=?""",
                     (status, status, now, status, now, status, now, status, now, result, error, action_id))


def docker_target(target: str) -> str:
    proc = subprocess.run(["/usr/bin/docker", "container", "inspect", "--format", "{{.Id}}", target],
                          capture_output=True, text=True, timeout=15, check=False)
    if proc.returncode or not re.fullmatch(r"[0-9a-f]{64}", proc.stdout.strip()):
        raise RuntimeError("Container is unavailable")
    return proc.stdout.strip()


def security_update_configuration_is_safe() -> bool:
    """Fail closed unless unattended-upgrades is security-only and never reboots."""
    proc = subprocess.run(["/usr/bin/apt-config", "dump"], capture_output=True, text=True, timeout=10, check=False)
    if proc.returncode:
        return False
    origins = []
    reboot = False
    for line in proc.stdout.splitlines():
        key, _, value = line.partition(" ")
        value = value.strip().strip(";\"").lower()
        if key.startswith(("Unattended-Upgrade::Allowed-Origins::", "Unattended-Upgrade::Origins-Pattern::")):
            origins.append(value)
        if key == "Unattended-Upgrade::Automatic-Reboot":
            reboot = value in {"true", "1", "yes"}
    return bool(origins) and all("security" in origin for origin in origins) and not reboot


def perform(action: str, target: str) -> str:
    # Every branch constructs its own fixed argv. Target values have passed policy validation.
    if action == "reboot":
        proc = subprocess.run(["/usr/bin/systemctl", "reboot"], capture_output=True, timeout=10, check=False)
    elif action == "shutdown":
        proc = subprocess.run(["/usr/bin/systemctl", "poweroff"], capture_output=True, timeout=10, check=False)
    elif action == "update_refresh":
        proc = subprocess.run(["/usr/bin/apt-get", "update"], capture_output=True, timeout=900, check=False)
    elif action == "update_security":
        if not Path("/usr/bin/unattended-upgrade").exists():
            raise RuntimeError("unattended-upgrades is not installed")
        if not security_update_configuration_is_safe():
            raise RuntimeError("Configure unattended-upgrades for security origins only and disable automatic reboot")
        proc = subprocess.run(["/usr/bin/unattended-upgrade"], capture_output=True, timeout=3600, check=False)
    elif action == "update_all":
        proc = subprocess.run(["/usr/bin/apt-get", "-y", "upgrade"], capture_output=True, timeout=3600, check=False,
                              env={"PATH": "/usr/sbin:/usr/bin:/sbin:/bin", "DEBIAN_FRONTEND": "noninteractive", "LC_ALL": "C"})
    elif action == "service_start":
        proc = subprocess.run(["/usr/bin/systemctl", "start", "--", target], capture_output=True, timeout=120, check=False)
    elif action == "service_stop":
        proc = subprocess.run(["/usr/bin/systemctl", "stop", "--", target], capture_output=True, timeout=120, check=False)
    elif action == "service_restart":
        proc = subprocess.run(["/usr/bin/systemctl", "restart", "--", target], capture_output=True, timeout=120, check=False)
    elif action == "container_start":
        proc = subprocess.run(["/usr/bin/docker", "container", "start", docker_target(target)], capture_output=True, timeout=120, check=False)
    elif action == "container_stop":
        proc = subprocess.run(["/usr/bin/docker", "container", "stop", docker_target(target)], capture_output=True, timeout=120, check=False)
    elif action == "container_restart":
        proc = subprocess.run(["/usr/bin/docker", "container", "restart", docker_target(target)], capture_output=True, timeout=120, check=False)
    elif action == "restart_health_agent":
        proc = subprocess.run(["/usr/bin/systemctl", "restart", "interstellar-agent.service"], capture_output=True, timeout=120, check=False)
    elif action == "restart_control_agent":
        proc = subprocess.run(["/usr/bin/systemctl", "restart", "interstellar-control-api.service"], capture_output=True, timeout=120, check=False)
    elif action == "restart_mdns":
        proc = subprocess.run(["/usr/bin/systemctl", "restart", "interstellar-mdns.service"], capture_output=True, timeout=120, check=False)
    elif action == "restart_docker":
        proc = subprocess.run(["/usr/bin/systemctl", "restart", "docker.service"], capture_output=True, timeout=180, check=False)
    elif action == "restart_tailscaled":
        proc = subprocess.run(["/usr/bin/systemctl", "restart", "tailscaled.service"], capture_output=True, timeout=180, check=False)
    else:
        raise ValueError("Unsupported action")
    if proc.returncode:
        raise RuntimeError(f"Action exited with status {proc.returncode}")
    return "Action completed"


def worker(action_id: str, action: str, target: str) -> None:
    try:
        with EXECUTION_LOCK:
            transition(action_id, "running")
            if action in {"reboot", "shutdown", "restart_control_agent"}:
                time.sleep(1)
                transition(action_id, "dispatched", result="Action dispatched")
            try:
                result = perform(action, target)
            except (OSError, subprocess.TimeoutExpired, RuntimeError, ValueError) as err:
                transition(action_id, "failed", error=str(err)[:180])
            else:
                if action not in {"reboot", "shutdown"}:
                    transition(action_id, "successful", result=result)
                # Reboot is reconciled against a new boot ID; shutdown stays dispatched.
    finally:
        SLOTS.release()


def dispatch(request: dict, peer_uid: int) -> dict:
    if peer_uid != CONTROL_UID:
        return {"error": "Unauthorized socket peer"}
    action_id, action, target, identity = (request.get(k) for k in ("action_id", "action", "target", "identity"))
    confirmation = request.get("confirmation", "")
    try:
        UUID(action_id)
        if not isinstance(identity, str) or not 1 <= len(identity) <= 200 or any(ord(c) < 32 for c in identity):
            raise ValueError("Invalid identity")
        validate(action, target, confirmation)
    except (TypeError, ValueError) as err:
        if isinstance(action_id, str) and isinstance(action, str) and isinstance(target, str) and isinstance(identity, str):
            try:
                UUID(action_id)
                record(action_id, action[:80], target[:128], identity[:200], "failed", str(err))
            except (ValueError, sqlite3.IntegrityError):
                pass
        return {"error": str(err)}
    if not SLOTS.acquire(blocking=False):
        record(action_id, action, target, identity, "failed", "Action queue is full")
        return {"error": "Action queue is full"}
    try:
        record(action_id, action, target, identity, "queued")
    except sqlite3.IntegrityError:
        SLOTS.release()
        return {"error": "Duplicate action ID"}
    except sqlite3.Error:
        SLOTS.release()
        return {"error": "Audit unavailable"}
    threading.Thread(target=worker, args=(action_id, action, target), daemon=True).start()
    return {"action_id": action_id, "status": "queued"}


def snapshot() -> dict:
    result = {"docker": {"installed": Path("/usr/bin/docker").exists(), "daemon_running": False,
                         "containers": [], "images": None, "disk_usage": []},
              "toolbox_version": None, "boot_time_utc": None}
    for line in Path("/proc/stat").read_text().splitlines():
        if line.startswith("btime "):
            result["boot_time_utc"] = datetime.fromtimestamp(int(line.split()[1]), timezone.utc).isoformat()
            break
    toolbox = Path("/usr/local/sbin/interstellar-toolbox")
    if toolbox.exists():
        match = re.search(r'^TOOLBOX_VERSION="([0-9.]+)"$', toolbox.read_text(errors="replace"), re.M)
        if match:
            result["toolbox_version"] = match.group(1)
    if not result["docker"]["installed"]:
        return result
    try:
        info = subprocess.run(["/usr/bin/docker", "info", "--format", "{{json .}}"],
                              capture_output=True, text=True, timeout=10, check=False)
        if info.returncode:
            return result
        parsed = json.loads(info.stdout)
        result["docker"].update({"daemon_running": True, "version": parsed.get("ServerVersion"),
                                 "images": parsed.get("Images"), "total": parsed.get("Containers"),
                                 "running": parsed.get("ContainersRunning"), "stopped": parsed.get("ContainersStopped")})
        containers = subprocess.run(["/usr/bin/docker", "ps", "-a", "--format", "{{json .}}"],
                                    capture_output=True, text=True, timeout=10, check=False)
        if containers.returncode == 0:
            for line in containers.stdout.splitlines()[:100]:
                item = json.loads(line)
                identifier = item.get("ID", "")
                if not re.fullmatch(r"[0-9a-f]{12,64}", identifier):
                    continue
                detail = subprocess.run(["/usr/bin/docker", "container", "inspect", "--format", "{{json .}}", identifier],
                                        capture_output=True, text=True, timeout=10, check=False)
                if detail.returncode:
                    continue
                data = json.loads(detail.stdout)
                state = data.get("State") or {}
                labels = (data.get("Config") or {}).get("Labels") or {}
                result["docker"]["containers"].append({
                    "id": data.get("Id"), "name": str(data.get("Name", "")).lstrip("/"),
                    "image": (data.get("Config") or {}).get("Image"),
                    "state": state.get("Status"), "health": (state.get("Health") or {}).get("Status"),
                    "started_at": state.get("StartedAt"), "restart_count": data.get("RestartCount"),
                    "ports": item.get("Ports"), "project": labels.get("com.docker.compose.project"),
                })
        usage = subprocess.run(["/usr/bin/docker", "system", "df", "--format", "{{json .}}"],
                               capture_output=True, text=True, timeout=10, check=False)
        if usage.returncode == 0:
            result["docker"]["disk_usage"] = [json.loads(line) for line in usage.stdout.splitlines()[:10]]
        compose = subprocess.run(["/usr/bin/docker", "compose", "version", "--short"],
                                 capture_output=True, text=True, timeout=5, check=False)
        if compose.returncode == 0:
            result["docker"]["compose_version"] = compose.stdout.strip()[:60]
    except (OSError, ValueError, subprocess.TimeoutExpired):
        pass
    return result


def main() -> None:
    global CONTROL_UID
    import pwd
    import grp
    CONTROL_UID = pwd.getpwnam("interstellar-control").pw_uid
    gid = grp.getgrnam("interstellar-control").gr_gid
    initialize()
    os.chown(DB_PATH, 0, gid)
    SOCKET_PATH.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
    if SOCKET_PATH.exists():
        SOCKET_PATH.unlink()
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(str(SOCKET_PATH))
    os.chown(SOCKET_PATH, 0, gid)
    os.chmod(SOCKET_PATH, 0o660)
    server.listen(16)
    while True:
        conn, _ = server.accept()
        with conn:
            conn.settimeout(5)
            _, uid, _ = struct.unpack("3i", conn.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i")))
            try:
                raw = conn.recv(4097)
                if len(raw) > 4096:
                    raise ValueError("Request too large")
                request = json.loads(raw)
                if not isinstance(request, dict):
                    raise ValueError("Invalid request")
                if request.get("query") == "state" and uid == CONTROL_UID:
                    response = snapshot()
                else:
                    response = dispatch(request, uid)
            except (ValueError, OSError, sqlite3.Error) as err:
                response = {"error": str(err)}
            conn.sendall(json.dumps(response).encode())


if __name__ == "__main__":
    main()

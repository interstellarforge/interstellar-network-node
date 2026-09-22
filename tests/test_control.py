"""Security and action protocol tests for the release-embedded control sources."""
from __future__ import annotations

import http.client
import importlib.util
import json
import os
import socket
import subprocess
import tempfile
import threading
import unittest
from pathlib import Path
from unittest.mock import patch
from uuid import uuid4

ROOT = Path(__file__).parents[1]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


helper = load("control_helper", ROOT / "control/control_helper.py")
api = load("control_api", ROOT / "control/control_api.py")


class UnixConnection(http.client.HTTPConnection):
    def __init__(self, path):
        super().__init__("localhost")
        self.path = path

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(self.path)


class ControlTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name)
        self.policy_path = self.path / "policy.json"
        self.policy_path.write_text(json.dumps({
            "expected_services": ["ssh", "docker"], "manageable_services": ["docker", "tailscaled"],
            "expected_containers": ["plex"], "manageable_containers": ["plex"],
            "sensitive_services_opt_in": [],
        }))
        self.db_path = self.path / "actions.db"
        self.patches = [patch.object(helper, "POLICY_PATH", self.policy_path),
                        patch.object(helper, "DB_PATH", self.db_path),
                        patch.object(helper, "CONTROL_UID", 1234),
                        patch.object(helper, "machine_id", return_value="machine-a"),
                        patch.object(helper, "boot_id", return_value="boot-a")]
        for item in self.patches:
            item.start()
            self.addCleanup(item.stop)
        helper.initialize()

    def test_target_policy_and_sensitive_opt_in(self):
        helper.validate("service_restart", "docker")
        helper.validate("container_stop", "plex")
        with patch.object(helper.socket, "gethostname", return_value="atlas"):
            with self.assertRaises(ValueError):
                helper.validate("reboot", "")
            helper.validate("reboot", "", "atlas")
        for action, target in (("service_restart", "ssh"), ("service_stop", "tailscaled"),
                               ("container_start", "unknown"), ("service_restart", "--root"),
                               ("reboot", "docker"), ("exec", ""), ("restart_tailscaled", "")):
            with self.subTest(action=action, target=target), self.assertRaises(ValueError):
                helper.validate(action, target)

    def test_rejected_peer_and_audited_action(self):
        request = {"action_id": str(uuid4()), "action": "service_restart", "target": "docker", "identity": "admin@example.com"}
        self.assertIn("error", helper.dispatch(request, 0))
        with helper.db() as conn:
            self.assertEqual([], conn.execute("SELECT * FROM actions").fetchall())
        with patch.object(helper.threading, "Thread") as thread:
            result = helper.dispatch(request, 1234)
            self.assertEqual("queued", result["status"])
            thread.assert_called_once()
        with helper.db() as conn:
            row = conn.execute("SELECT * FROM actions WHERE action_id=?", (request["action_id"],)).fetchone()
        self.assertEqual("machine-a", row["machine_id"])
        self.assertEqual("admin@example.com", row["identity"])
        self.assertEqual("docker", row["target"])

    def test_security_updates_fail_closed(self):
        with patch.object(helper.subprocess, "run") as run:
            run.return_value.returncode=0
            run.return_value.stdout=('Unattended-Upgrade::Allowed-Origins:: "Ubuntu:noble-security";\n'
                                     'Unattended-Upgrade::Automatic-Reboot "true";\n')
            self.assertFalse(helper.security_update_configuration_is_safe())
            run.return_value.stdout=('Unattended-Upgrade::Allowed-Origins:: "Ubuntu:noble-security";\n'
                                     'Unattended-Upgrade::Automatic-Reboot "false";\n')
            self.assertTrue(helper.security_update_configuration_is_safe())
            run.return_value.stdout=('Unattended-Upgrade::Allowed-Origins:: "Ubuntu:noble-updates";\n')
            self.assertFalse(helper.security_update_configuration_is_safe())

    def test_no_shell_and_fixed_service_argv(self):
        with patch.object(helper.subprocess, "run") as run:
            run.return_value.returncode = 0
            helper.perform("service_restart", "docker")
            self.assertEqual(["/usr/bin/systemctl", "restart", "--", "docker"], run.call_args.args[0])
            self.assertFalse(run.call_args.kwargs.get("shell", False))

    def test_power_action_finishes_after_new_boot(self):
        action_id = str(uuid4())
        helper.record(action_id, "reboot", "", "admin@example.com", "queued")
        helper.transition(action_id, "running")
        helper.transition(action_id, "dispatched")
        with helper.db() as conn:
            before = conn.execute("SELECT * FROM actions WHERE action_id=?", (action_id,)).fetchone()
        self.assertEqual("dispatched", before["status"])
        self.assertIsNotNone(before["action_started_at"])
        self.assertIsNotNone(before["dispatched_at"])
        with patch.object(helper, "boot_id", return_value="boot-b"), \
             patch.object(helper, "current_boot_time", return_value=helper.datetime.now(helper.timezone.utc)):
            helper.initialize()
        with helper.db() as conn:
            row = conn.execute("SELECT * FROM actions WHERE action_id=?", (action_id,)).fetchone()
        self.assertEqual("successful", row["status"])
        self.assertEqual("New boot observed", row["result"])
        self.assertIsNotNone(row["finished_at"])
        self.assertIsNotNone(row["reboot_duration_seconds"])

    def test_shutdown_stays_dispatched_after_new_boot(self):
        action_id = str(uuid4())
        helper.record(action_id, "shutdown", "", "admin@example.com", "queued")
        helper.transition(action_id, "running")
        helper.transition(action_id, "dispatched")
        with patch.object(helper, "boot_id", return_value="boot-b"):
            helper.initialize()
        with helper.db() as conn:
            row = conn.execute("SELECT status, finished_at FROM actions WHERE action_id=?", (action_id,)).fetchone()
        self.assertEqual("dispatched", row["status"])
        self.assertIsNone(row["finished_at"])

    def test_running_power_action_interrupted_before_dispatch_fails(self):
        action_id = str(uuid4())
        helper.record(action_id, "reboot", "", "admin@example.com", "queued")
        helper.transition(action_id, "running")
        with patch.object(helper, "boot_id", return_value="boot-b"):
            helper.initialize()
        with helper.db() as conn:
            row = conn.execute("SELECT status, error FROM actions WHERE action_id=?", (action_id,)).fetchone()
        self.assertEqual("failed", row["status"])
        self.assertEqual("Interrupted before dispatch", row["error"])

    def test_control_restart_passes_through_dispatched(self):
        action_id = str(uuid4())
        helper.record(action_id, "restart_control_agent", "", "admin@example.com", "queued")
        states = []
        original = helper.transition

        def transition(*args, **kwargs):
            states.append(args[1])
            original(*args, **kwargs)

        with patch.object(helper, "transition", side_effect=transition), \
             patch.object(helper.time, "sleep"), \
             patch.object(helper, "perform", return_value="Action completed"), \
             patch.object(helper.SLOTS, "release"):
            helper.worker(action_id, "restart_control_agent", "")
        self.assertEqual(["running", "dispatched", "successful"], states)

    def test_tailscale_semantic_minimum(self):
        for client, daemon, expected in (("1.98.8", "1.98.8", False),
                                         ("1.98.9", "1.98.8", False),
                                         ("1.98.8", "1.98.9", False),
                                         ("1.98.9", "1.98.9", True),
                                         ("1.98.9", "1.98.9-abcdef0123-123456abcd", True),
                                         ("1.98.9-dev", "1.98.9", False),
                                         ("1.100.0", "1.100.0", True),
                                         ("2.0.0", "2.0.0", True),
                                         ("unknown", "1.98.9", False)):
            with self.subTest(client=client, daemon=daemon), patch.object(api.subprocess, "run") as run:
                run.return_value.returncode = 0
                run.return_value.stdout = json.dumps({"short": client, "daemonLong": daemon})
                self.assertEqual(expected, api.tailscale_control_status()["control_available"])

    def test_toolbox_tailscale_gate_uses_numeric_versions(self):
        box = (ROOT / "toolbox/interstellar-network-toolbox.sh").read_text()
        start = box.index("tailscale_control_version_supported() {")
        end = box.index("\nwrite_control_helper_python()", start)
        script = box[start:end] + "\ntailscale_control_version_supported\n"
        fake = self.path / "tailscale"
        fake.write_text('#!/bin/sh\nif [ "$2" = "--daemon" ]; then printf \'{"short":"%s","daemonLong":"%s"}\\n\' "$TEST_TAILSCALE_VERSION" "$TEST_DAEMON_VERSION"; else printf "%s\\n" "$TEST_TAILSCALE_VERSION"; fi\n')
        fake.chmod(0o755)
        for client, daemon, expected in (("1.98.8", "1.98.8", 1), ("1.98.9", "1.98.8", 1),
                                         ("1.98.9", "1.98.9", 0), ("1.100.0", "1.100.0", 0),
                                         ("1.98.9-dev", "1.98.9", 1)):
            with self.subTest(client=client, daemon=daemon):
                result = subprocess.run(["bash", "-c", script], capture_output=True, text=True,
                                        env={**os.environ, "PATH": f"{self.path}:{os.environ['PATH']}",
                                             "TEST_TAILSCALE_VERSION": client,
                                             "TEST_DAEMON_VERSION": daemon}, check=False)
                self.assertEqual(expected, result.returncode)
                self.assertIn("Minimum for control: 1.98.9", result.stdout)

    def test_outdated_tailscale_rejects_control_post(self):
        path = str(self.path / "old-api.sock")
        server = api.ThreadingUnixStreamServer(path, api.Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        caps = json.dumps({api.CAPABILITY: [{}]})
        with patch.object(api, "tailscale_control_status", return_value={"control_available": False,
             "control_unavailable_reason": "Tailscale 1.98.9 or newer is required for control"}), \
             patch.object(api, "send_action") as send:
            connection = UnixConnection(path)
            connection.request("POST", "/actions/reboot", '{"confirm_hostname":"atlas"}',
                               {"Tailscale-App-Capabilities": caps})
            response = connection.getresponse()
            self.assertEqual(503, response.status)
            response.read()
            connection.close()
            send.assert_not_called()

    def test_private_api_socket_and_no_tcp_control_listener(self):
        source=(ROOT / "control/control_api.py").read_text()
        unit=(ROOT / "toolbox/interstellar-network-toolbox.sh").read_text()
        self.assertIn("ThreadingUnixStreamServer",source)
        self.assertIn("os.chmod(API_SOCKET, 0o600)",source)
        self.assertNotIn("ThreadingHTTPServer",source)
        self.assertIn("RuntimeDirectoryMode=0700",unit)
        self.assertIn("RestrictAddressFamilies=AF_UNIX",unit)
        self.assertIn("os.chmod(SOCKET_PATH, 0o660)", (ROOT / "control/control_helper.py").read_text())
        self.assertNotIn("/actions/wake", source)

    def test_health_agent_has_no_post_handler(self):
        box = (ROOT / "toolbox/interstellar-network-toolbox.sh").read_text()
        start = box.index("write_agent_python() {")
        start = box.index("<<'PYEOF'\n", start) + len("<<'PYEOF'\n")
        end = box.index("\nPYEOF", start)
        import ast
        tree = ast.parse(box[start:end])
        handler = next(node for node in tree.body if isinstance(node, ast.ClassDef) and node.name == "Handler")
        methods = {node.name for node in handler.body if isinstance(node, ast.FunctionDef)}
        self.assertIn("do_GET", methods)
        self.assertNotIn("do_POST", methods)
        self.assertNotIn("do_PUT", methods)

    def test_api_requires_capability_and_rejects_invalid_targets(self):
        version_patch = patch.object(api, "tailscale_control_status", return_value={"control_available": True})
        version_patch.start()
        self.addCleanup(version_patch.stop)
        path = str(self.path / "api.sock")
        server = api.ThreadingUnixStreamServer(path, api.Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        connection = UnixConnection(path)
        connection.request("POST", "/actions/reboot", "{}", {"Content-Type": "application/json"})
        response = connection.getresponse()
        self.assertEqual(403, response.status)
        response.read()
        connection.close()
        connection = UnixConnection(path)
        caps = json.dumps({api.CAPABILITY: [{}]})
        connection.request("POST", "/actions/reboot", "{}",
                           {"Tailscale-App-Capabilities": caps, "Content-Type": "application/json"})
        response = connection.getresponse()
        self.assertEqual(400, response.status)
        response.read()
        connection.close()
        connection = UnixConnection(path)
        connection.request("POST", "/actions/service/restart", '{"service":"--evil"}',
                           {"Tailscale-App-Capabilities": caps, "Content-Type": "application/json"})
        response = connection.getresponse()
        self.assertEqual(400, response.status)
        response.read()
        connection.close()
        connection = UnixConnection(path)
        connection.request("POST", "/actions/update/install", '{"type":"full-upgrade"}',
                           {"Tailscale-App-Capabilities": caps, "Content-Type": "application/json"})
        response = connection.getresponse()
        self.assertEqual(400, response.status)
        response.read()
        connection.close()
        connection = UnixConnection(path)
        with patch.object(api, "send_action", return_value={"action_id": str(uuid4()), "status": "queued"}) as send:
            connection.request("POST", "/actions/docker/restart", '{"container":"plex"}',
                               {"Tailscale-App-Capabilities": caps, "Content-Type": "application/json"})
            response = connection.getresponse()
            self.assertEqual(202, response.status)
            response.read()
            send.assert_called_once_with("container_restart", "plex", "tailscale-tagged-node", "")
        connection.close()


if __name__ == "__main__":
    unittest.main()

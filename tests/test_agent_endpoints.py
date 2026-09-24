"""Health agent endpoint regression tests.

On a Debian 11 / Python 3.9 LXC container `/` returned valid JSON while
`/health` and `/stats` died with "Empty reply from server", because
`cpu_percentages()` raised `TypeError: zip() takes no keyword arguments` and the
exception escaped `do_GET`, closing the socket.

These tests drive the real request handler over a real socket and run the real
`cpu_percentages()` on this machine's `/proc/stat`. The collector is never
mocked away, so the failing path is genuinely executed.
"""
from __future__ import annotations

import importlib.util
import json
import shutil
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer
from pathlib import Path
from unittest.mock import patch

BOX = Path(__file__).parents[1] / "toolbox/interstellar-network-toolbox.sh"


def load_agent():
    """Import the agent exactly as tests/test_wol.py does, minus the server start."""
    source = BOX.read_text()
    start = source.index("write_agent_python() {")
    start = source.index("<<'PYEOF'\n", start) + len("<<'PYEOF'\n")
    end = source.index("\nhttpd = ThreadingHTTPServer", start)
    with tempfile.NamedTemporaryFile("w", suffix=".py", delete=False) as handle:
        handle.write(source[start:end])
        path = Path(handle.name)
    try:
        spec = importlib.util.spec_from_file_location("interstellar_agent", path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module
    finally:
        path.unlink()


agent = load_agent()


class EndpointTestCase(unittest.TestCase):
    """Serves the real Handler on a loopback port and makes real requests."""

    def serve(self):
        server = ThreadingHTTPServer(("127.0.0.1", 0), agent.Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        # shutdown() stops serving; server_close() releases the listening socket.
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        return f"http://127.0.0.1:{server.server_port}"

    def get(self, base, path):
        try:
            with urllib.request.urlopen(base + path, timeout=30) as response:
                return response.status, response.read().decode(), dict(response.headers)
        except urllib.error.HTTPError as err:
            with err:
                return err.code, err.read().decode(), dict(err.headers)


class EndpointTests(EndpointTestCase):
    def test_root_health_and_stats_all_return_valid_json(self):
        """The three endpoints that dmt-prod exercised, end to end."""
        base = self.serve()
        for path in ("/", "/health", "/stats"):
            with self.subTest(path=path):
                status, body, headers = self.get(base, path)
                self.assertIn(status, (200, 503), f"{path} returned {status}")
                self.assertEqual("application/json", headers.get("Content-Type"))
                payload = json.loads(body)
                self.assertIsInstance(payload, dict)
                self.assertTrue(body, f"{path} returned an empty body")

    def test_stats_runs_the_real_cpu_collector(self):
        """cpu_percentages() is the function that used to raise; run it for real."""
        base = self.serve()
        status, body, _ = self.get(base, "/stats")
        self.assertEqual(200, status)
        payload = json.loads(body)
        self.assertEqual("ok", payload["status"])
        self.assertIn("cpu", payload)
        self.assertIn("used_percent", payload["cpu"])
        self.assertNotIn("cpu", payload["collector_errors"],
                         f"CPU collection failed: {payload['collector_errors']}")

    def test_cpu_percentages_directly(self):
        """The exact code path from the journal traceback."""
        result = agent.cpu_percentages()
        self.assertEqual({"used_percent", "iowait_percent", "steal_percent"}, set(result))
        if result["used_percent"] is not None:
            self.assertGreaterEqual(result["used_percent"], 0.0)
            self.assertLessEqual(result["used_percent"], 100.0)

    def test_metrics_endpoint_still_serves_prometheus(self):
        base = self.serve()
        status, body, headers = self.get(base, "/metrics")
        self.assertEqual(200, status)
        self.assertIn("text/plain", headers.get("Content-Type", ""))
        self.assertIn("interstellar_agent_info", body)

    def test_unknown_path_is_a_json_404(self):
        base = self.serve()
        status, body, headers = self.get(base, "/nope")
        self.assertEqual(404, status)
        self.assertEqual("application/json", headers.get("Content-Type"))
        self.assertEqual("not_found", json.loads(body)["error"])

    def test_health_reports_agent_version(self):
        base = self.serve()
        _, body, _ = self.get(base, "/health")
        self.assertEqual(agent.VERSION, json.loads(body)["agent_version"])


class ResilienceTests(EndpointTestCase):
    def test_one_failing_collector_degrades_only_that_field(self):
        """A broken collector must not take the whole response with it."""
        base = self.serve()
        with patch.object(agent, "thermal_stats", side_effect=OSError("sensors gone")):
            status, body, _ = self.get(base, "/stats")
        self.assertEqual(200, status)
        payload = json.loads(body)
        self.assertEqual("ok", payload["status"], "payload validity must not flip")
        self.assertTrue(payload["degraded"])
        self.assertEqual("OSError", payload["collector_errors"]["temperatures"])
        self.assertEqual([], payload["temperatures"])
        # Everything else still collected.
        self.assertIn("used_percent", payload["cpu"])
        self.assertIn("hostname", payload["host"])

    def test_the_original_bug_would_now_degrade_instead_of_dropping(self):
        """Simulate the dmt-prod TypeError; the response must survive it."""
        boom = TypeError("zip() takes no keyword arguments")
        base = self.serve()
        with patch.object(agent, "cpu_percentages", side_effect=boom):
            status, body, _ = self.get(base, "/stats")
        self.assertEqual(200, status, "the connection must not be dropped")
        payload = json.loads(body)
        self.assertTrue(payload["degraded"])
        self.assertEqual("TypeError", payload["collector_errors"]["cpu"])
        self.assertIsNone(payload["cpu"]["used_percent"])

    def test_collector_errors_never_leak_messages_or_paths(self):
        """Only the exception type is published; detail goes to the journal."""
        secret = FileNotFoundError(2, "No such file or directory", "/etc/interstellar/secret.json")
        base = self.serve()
        with patch.object(agent, "filesystem_stats", side_effect=secret):
            status, body, _ = self.get(base, "/stats")
        self.assertEqual(200, status)
        self.assertNotIn("/etc/interstellar/secret.json", body)
        self.assertNotIn("No such file", body)
        self.assertEqual("FileNotFoundError",
                         json.loads(body)["collector_errors"]["filesystems"])

    def test_health_reports_degraded_when_a_collector_fails(self):
        base = self.serve()
        with patch.object(agent, "thermal_stats", side_effect=OSError("sensors gone")):
            status, body, _ = self.get(base, "/health")
        payload = json.loads(body)
        self.assertEqual(503, status)
        self.assertEqual("degraded", payload["status"])
        self.assertEqual("OSError", payload["collector_errors"]["temperatures"])

    def test_total_failure_returns_json_500_not_a_closed_socket(self):
        """Worst case: the whole payload builder explodes."""
        base = self.serve()
        with patch.object(agent, "collect_stats", side_effect=RuntimeError("total loss")):
            status, body, headers = self.get(base, "/stats")
        self.assertEqual(500, status)
        self.assertEqual("application/json", headers.get("Content-Type"))
        payload = json.loads(body)
        self.assertEqual("error", payload["status"])
        self.assertEqual("internal_error", payload["error"])
        self.assertNotIn("total loss", body, "error detail must stay in the journal")
        self.assertNotIn("Traceback", body)


class DegradedReportingTests(EndpointTestCase):
    """A degraded host must say why, in the response itself.

    dmt-prod returned 503 from /health and the Toolbox printed only
    "Expecting value: line 1 column 1", because `curl --fail` swallows the body
    of a non-2xx response. The payload has to carry the reason, and the tooling
    has to show it.
    """

    def test_health_names_the_failing_expected_service(self):
        stats = agent.collect_stats()
        stats["service_policy"]["healthy"] = False
        stats["service_policy"]["problems"] = [{"service": "tailscaled", "state": "inactive"}]
        with patch.object(agent, "collect_stats", return_value=stats):
            health = agent.minimal_health()
        self.assertEqual("degraded", health["status"])
        self.assertIn("expected services not active: tailscaled", health["degraded_reasons"])

    def test_health_names_failed_units_and_full_disk(self):
        stats = agent.collect_stats()
        stats["system"]["failed_systemd_units"] = 2
        stats["disk_root"] = {"used_percent": 97.0}
        with patch.object(agent, "collect_stats", return_value=stats):
            health = agent.minimal_health()
        self.assertIn("2 failed systemd unit(s)", health["degraded_reasons"])
        self.assertIn("root filesystem is 97.0% full", health["degraded_reasons"])

    def test_health_names_collector_failures(self):
        base = self.serve()
        with patch.object(agent, "thermal_stats", side_effect=OSError("no sensors")):
            _, body, _ = self.get(base, "/health")
        payload = json.loads(body)
        self.assertEqual("degraded", payload["status"])
        self.assertIn("collectors failed: temperatures", payload["degraded_reasons"])

    def test_healthy_host_has_no_reasons(self):
        stats = agent.collect_stats()
        stats["service_policy"]["healthy"] = True
        stats["service_policy"]["problems"] = []
        stats["system"]["failed_systemd_units"] = 0
        stats["disk_root"] = {"used_percent": 10.0}
        stats["time"] = {"synchronized": True}
        stats["collector_errors"] = {}
        with patch.object(agent, "collect_stats", return_value=stats):
            health = agent.minimal_health()
        self.assertEqual("ok", health["status"])
        self.assertEqual([], health["degraded_reasons"])

    def test_container_clock_is_not_counted_as_degraded(self):
        """A container does not own its clock; the host synchronizes it."""
        stats = agent.collect_stats()
        stats["service_policy"]["healthy"] = True
        stats["service_policy"]["problems"] = []
        stats["system"]["failed_systemd_units"] = 0
        stats["disk_root"] = {"used_percent": 10.0}
        stats["collector_errors"] = {}
        stats["time"] = {"synchronized": False}

        stats["host"]["virtualization"] = "lxc"
        with patch.object(agent, "collect_stats", return_value=stats):
            self.assertEqual("ok", agent.minimal_health()["status"])

        # The same unsynchronized clock on bare metal is still a real problem.
        stats["host"]["virtualization"] = "none"
        with patch.object(agent, "collect_stats", return_value=stats):
            health = agent.minimal_health()
        self.assertEqual("degraded", health["status"])
        self.assertIn("clock is not NTP synchronized", health["degraded_reasons"])

    def test_degraded_health_is_still_valid_json_over_http(self):
        """503 must still carry a parseable, self-explanatory body."""
        stats = agent.collect_stats()
        stats["service_policy"]["healthy"] = False
        stats["service_policy"]["problems"] = [{"service": "ssh", "state": "inactive"}]
        base = self.serve()
        with patch.object(agent, "collect_stats", return_value=stats):
            status, body, headers = self.get(base, "/health")
        self.assertEqual(503, status)
        self.assertEqual("application/json", headers.get("Content-Type"))
        payload = json.loads(body)
        self.assertEqual("degraded", payload["status"])
        self.assertTrue(payload["degraded_reasons"])


class ToolboxProbeTests(unittest.TestCase):
    """The Toolbox test commands must show the body, especially on a non-2xx."""

    @staticmethod
    def probe_source() -> str:
        import re
        box = (Path(__file__).parents[1] / "toolbox/interstellar-network-toolbox.sh").read_text()
        match = re.search(r"^agent_http_probe\(\) \{.*?^\}$", box, re.S | re.M)
        assert match, "agent_http_probe not found"
        return match.group(0)

    def test_probe_does_not_use_curl_fail(self):
        """--fail discards the body, which is the only thing that explains a 503."""
        source = self.probe_source()
        self.assertNotIn("curl -fsS", source)
        self.assertNotIn("--fail", source)
        self.assertIn("%{http_code}", source)

    @unittest.skipUnless(shutil.which("curl"), "curl is not installed")
    def test_probe_prints_body_and_status_for_a_503(self):
        import subprocess
        import textwrap
        payload = {"status": "degraded",
                   "degraded_reasons": ["expected services not active: tailscaled"]}
        server = ThreadingHTTPServer(("127.0.0.1", 0), self.make_handler(503, payload))
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        script = textwrap.dedent(f"""
            set -Eeuo pipefail
            warn() {{ printf '[WARN] %s\\n' "$*"; }}
            agent_local_url() {{ printf 'http://127.0.0.1:{server.server_port}'; }}
            {self.probe_source()}
            agent_http_probe /health
        """)
        result = subprocess.run(["bash", "-c", script], capture_output=True, text=True)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("HTTP 503", result.stdout)
        self.assertIn("expected services not active: tailscaled", result.stdout)
        self.assertIn("degraded", result.stdout)

    @staticmethod
    def make_handler(code, payload):
        from http.server import BaseHTTPRequestHandler

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_GET(self):
                body = json.dumps(payload).encode()
                self.send_response(code)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

        return Handler

    def test_menu_entries_survive_a_failing_probe(self):
        """A failed probe must return to the menu, not exit the Toolbox.

        The script runs under `set -Eeuo pipefail`, so an unguarded non-zero
        return from a menu action terminates the whole program before `pause`.
        """
        box = (Path(__file__).parents[1] / "toolbox/interstellar-network-toolbox.sh").read_text()
        for entry in ("agent_test_health", "agent_test_stats", "agent_test_metrics"):
            self.assertIn(f"{entry} || true", box,
                          f"{entry} menu entry must not be able to exit the Toolbox")


class ContainerTests(unittest.TestCase):
    """An LXC guest must degrade, not fail, and must not claim hardware it lacks."""

    def test_container_detected_without_systemd_detect_virt(self):
        with patch.object(agent, "run", return_value=""), \
             patch.object(agent.os.path, "exists", return_value=False), \
             patch.object(agent, "read_text", side_effect=lambda p: "lxc\n" if p == "/run/systemd/container" else None):
            self.assertEqual("lxc", agent.virtualization())
            self.assertTrue(agent.is_container())

    def test_container_detected_from_pid1_cgroup(self):
        def fake_read(path):
            if path == "/proc/1/cgroup":
                return "0::/lxc.payload.101/system.slice/interstellar-agent.service"
            return None
        with patch.object(agent, "run", return_value=""), \
             patch.object(agent.os.path, "exists", return_value=False), \
             patch.object(agent, "read_text", side_effect=fake_read), \
             patch("builtins.open", side_effect=OSError):
            self.assertEqual("lxc", agent.virtualization())

    def test_systemd_detect_virt_still_wins_when_present(self):
        with patch.object(agent, "run", return_value="kvm"):
            self.assertEqual("kvm", agent.virtualization())
            self.assertFalse(agent.is_container())

    def test_bare_metal_still_reports_none(self):
        with patch.object(agent, "run", return_value=""), \
             patch.object(agent, "container_type", return_value=None):
            self.assertEqual("none", agent.virtualization())
            self.assertFalse(agent.is_container())

    def test_wake_on_lan_is_not_applicable_in_a_container(self):
        with patch.object(agent, "is_container", return_value=True):
            result = agent.wake_on_lan_stats()
        self.assertFalse(result["supported"])
        self.assertFalse(result["enabled"])
        self.assertIn("container", result["unavailable_reason"])

    def test_missing_hardware_telemetry_is_empty_not_fatal(self):
        """No thermal zones, no block devices: empty lists, no exception."""
        with patch.object(agent.glob, "glob", return_value=[]):
            self.assertEqual([], agent.thermal_stats())
            self.assertEqual([], agent.disk_io_stats())

    def test_stats_survives_a_container_shaped_environment(self):
        """Nothing hardware-related available; the payload must still build."""
        with patch.object(agent.glob, "glob", return_value=[]), \
             patch.object(agent, "run", return_value=""), \
             patch.object(agent, "is_container", return_value=True):
            payload = agent.collect_stats()
        self.assertEqual("ok", payload["status"])
        self.assertEqual([], payload["temperatures"])
        self.assertEqual([], payload["disk_io"])
        self.assertIn("hostname", payload["host"])
        self.assertFalse(payload["wake_on_lan"]["supported"])


if __name__ == "__main__":
    unittest.main()

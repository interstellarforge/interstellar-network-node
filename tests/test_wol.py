"""WoL policy and read-only health telemetry tests for embedded release code."""
import importlib.util
import io
import json
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

BOX = Path(__file__).parents[1] / "toolbox/interstellar-network-toolbox.sh"


def embedded(name):
    source = BOX.read_text()
    start = source.index(f"{name}() {{")
    start = source.index("<<'PYEOF'\n", start) + len("<<'PYEOF'\n")
    end = source.index("\nPYEOF", start)
    if name == "write_agent_python":
        end = source.index("\nhttpd = ThreadingHTTPServer", start)
    with tempfile.NamedTemporaryFile("w", suffix=".py", delete=False) as handle:
        handle.write(source[start:end])
        path = Path(handle.name)
    try:
        spec = importlib.util.spec_from_file_location(name, path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module
    finally:
        path.unlink()


wol = embedded("write_wol_python")
agent = embedded("write_agent_python")


class WolTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        root = Path(temp.name)
        self.net = root / "net"
        self.net.mkdir()
        self.config = root / "wol.json"
        self.eth = self.net / "enp3s0"
        self.eth.mkdir()
        (self.eth / "device").touch()
        (self.eth / "address").write_text("aa:bb:cc:dd:ee:ff\n")
        virtual = self.net / "veth0"
        virtual.mkdir()
        (virtual / "address").write_text("11:22:33:44:55:66\n")
        for item, value in (("NET", self.net), ("CONFIG", self.config)):
            p = patch.object(wol, item, value)
            p.start()
            self.addCleanup(p.stop)
        for item in (patch.object(wol.os, "chown"), patch.object(wol, "virtual_machine", return_value=False)):
            item.start()
            self.addCleanup(item.stop)

    def fake_run(self, args, **kwargs):
        if args[:2] == [wol.ETHTOOL, "enp3s0"]:
            return SimpleNamespace(returncode=0, stdout="Supports Wake-on: pumbg\nWake-on: g\n")
        return SimpleNamespace(returncode=0, stdout="")

    def test_detect_capability_enabled_and_persistence(self):
        with patch.object(wol.subprocess, "run", side_effect=self.fake_run) as run:
            self.assertEqual(["enp3s0"], wol.interfaces())
            self.assertTrue(wol.details("enp3s0")["supported"])
            self.assertTrue(wol.details("enp3s0")["enabled"])
            wol.main(["select", "enp3s0"])
            wol.main(["enable"])
            self.assertEqual("aa:bb:cc:dd:ee:ff", json.loads(self.config.read_text())["mac_address"])
            self.assertTrue(json.loads(self.config.read_text())["enabled"])
            wol.main(["test"])
            self.assertIn(([wol.ETHTOOL, "-s", "enp3s0", "wol", "g"],), [c.args for c in run.call_args_list])
            wol.main(["disable"])
            self.assertFalse(json.loads(self.config.read_text())["enabled"])

    def test_unsupported_nic_and_invalid_interface(self):
        def unsupported(args, **kwargs):
            return SimpleNamespace(returncode=0, stdout="Supports Wake-on: d\nWake-on: d\n")
        with patch.object(wol.subprocess, "run", side_effect=unsupported):
            self.assertFalse(wol.details("enp3s0")["supported"])
            with self.assertRaises(ValueError):
                wol.main(["select", "enp3s0"])
            with self.assertRaises(ValueError):
                wol.main(["select", "enp3s0;touch /tmp/evil"])
            with self.assertRaises(ValueError):
                wol.details("../../tmp")
        self.assertFalse(self.config.exists())

    def test_health_telemetry_and_no_privileged_handler(self):
        config = {"enabled": True, "interface": "enp3s0", "mac_address": "aa:bb:cc:dd:ee:ff"}
        real_open = open

        def fake_open(path, *args, **kwargs):
            if path == "/etc/interstellar/wol.json":
                return io.StringIO(json.dumps(config))
            return real_open(path, *args, **kwargs)

        def fake_run(args, **kwargs):
            if "ethtool" in args[0]:
                return "Supports Wake-on: pumbg\nWake-on: g"
            if args[1:3] == ["-j", "-4"]:
                return json.dumps([{"addr_info": [{"family":"inet","scope":"global","broadcast":"192.168.1.255"}]}])
            return ""

        with patch("builtins.open", side_effect=fake_open), \
             patch.object(agent.os.path, "exists", return_value=True), \
             patch.object(agent, "read_text", return_value="aa:bb:cc:dd:ee:ff"), \
             patch.object(agent, "virtualization", return_value="none"), \
             patch.object(agent, "run", side_effect=fake_run):
            result = agent.wake_on_lan_stats()
        self.assertEqual({"supported": True, "enabled": True, "interface": "enp3s0",
                          "mac_address": "aa:bb:cc:dd:ee:ff", "broadcast_address": "192.168.1.255"}, result)
        self.assertFalse(hasattr(agent.Handler, "do_POST"))

    def status(self, version="1.98.9", daemon="1.98.9", services=None, installed=True):
        services = services or {"interstellar-control-api": "active",
                                "interstellar-control-helper": "active"}
        with patch.object(agent.os.path, "exists", return_value=installed):
            return agent.control_plane_status({"version": version, "daemon_version": daemon}, services)

    def test_health_reports_control_unavailable_without_losing_telemetry(self):
        old = self.status(version="1.98.8", daemon="1.98.8")
        self.assertFalse(old["control_available"])
        self.assertEqual("1.98.9", old["tailscale_control_minimum_version"])
        self.assertFalse(old["tailscale_version_supported"])
        mixed = self.status(version="1.98.9", daemon="1.98.8")
        self.assertFalse(mixed["control_available"])
        patched = self.status()
        self.assertTrue(patched["control_available"])

    def test_control_plane_status_separates_local_facts(self):
        """Local service state, Serve expectation and HA authorization are distinct.

        The health agent can see the first two and can never see the third, so it
        must not publish anything that reads as "control works for Home Assistant".
        """
        ready = self.status()
        self.assertTrue(ready["installed"])
        self.assertTrue(ready["api_service_active"])
        self.assertTrue(ready["helper_service_active"])
        self.assertTrue(ready["serve_expected"])
        self.assertTrue(ready["control_service_ready"])
        self.assertIsNone(ready["control_service_unavailable_reason"])
        # No field may claim remote authorization; only the control API knows.
        self.assertNotIn("control_authorized_from_ha", ready)

        absent = self.status(installed=False)
        self.assertFalse(absent["installed"])
        self.assertFalse(absent["serve_expected"])
        self.assertEqual("Control plane is not installed", absent["control_service_unavailable_reason"])

        stopped = self.status(services={"interstellar-control-api": "inactive",
                                        "interstellar-control-helper": "active"})
        self.assertFalse(stopped["api_service_active"])
        self.assertTrue(stopped["helper_service_active"])
        # Serve is still expected to exist; only the service is down.
        self.assertTrue(stopped["serve_expected"])
        self.assertEqual("Control API service is not active",
                         stopped["control_service_unavailable_reason"])

        helper_down = self.status(services={"interstellar-control-api": "active",
                                            "interstellar-control-helper": "failed"})
        self.assertEqual("Control helper service is not active",
                         helper_down["control_service_unavailable_reason"])

    def test_control_services_fall_back_to_runtime_directory(self):
        """`systemctl show` can be unavailable to the sandboxed agent.

        These units run as `python3`, so /proc comm matching cannot find them and
        the old fallback reported a running control API as inactive. systemd
        removes RuntimeDirectory when a unit stops, so the directory is the
        reliable unprivileged signal.
        """
        with patch.object(agent, "run", return_value=""), \
             patch.object(agent.os.path, "isdir", return_value=True):
            self.assertEqual("active", agent.service_state("interstellar-control-api"))
            self.assertEqual("active", agent.service_state("interstellar-control-helper"))
        with patch.object(agent, "run", return_value=""), \
             patch.object(agent.os.path, "isdir", return_value=False):
            self.assertEqual("inactive", agent.service_state("interstellar-control-api"))
        # systemd remains authoritative when it answers.
        with patch.object(agent, "run", return_value="active"):
            self.assertEqual("active", agent.service_state("interstellar-control-api"))


if __name__ == "__main__":
    unittest.main()

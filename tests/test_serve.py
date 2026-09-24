"""Tailscale Serve topology tests for the Toolbox control plane.

Atlas and Jupiter both ran with the control services active but no control Serve
listener, so Home Assistant could never reach the control API. These tests drive
the real Toolbox shell functions against a stub `tailscale` binary.
"""
from __future__ import annotations

import importlib.util
import json
import os
import re
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).parents[1]
TOOLBOX = ROOT / "toolbox/interstellar-network-toolbox.sh"
SOURCE = TOOLBOX.read_text()

CAPABILITY = "interstellarnetwork.nl/cap/server-control"
CONTROL_TARGET = "unix:/run/interstellar-control-api/api.sock"
HOST = "atlas.tail24b95.ts.net"

# Functions under test, lifted out of the root-only Toolbox.
FUNCTIONS = (
    "python_version", "python_supported",
    "tailscale_available", "tailscale_control_version_ok", "health_serve_port",
    "magicdns_name", "serve_config_json", "serve_state_vars", "control_serve_url",
    "ensure_health_serve", "ensure_control_serve", "control_installed", "unit_state",
    "control_show_status", "control_check", "control_self_check", "control_grant_guidance",
)


def extract(name: str) -> str:
    match = re.search(rf"^{re.escape(name)}\(\) \{{.*?^\}}$", SOURCE, re.S | re.M)
    if not match:
        raise AssertionError(f"Toolbox function {name} not found")
    return match.group(0)


PREAMBLE = """
set -Eeuo pipefail
ok()   { printf '[OK] %s\\n' "$*"; }
warn() { printf '[WARN] %s\\n' "$*"; }
info() { printf '[INFO] %s\\n' "$*"; }
fix()  { printf '[FIX] %s\\n' "$*"; }
agent_env_value() { printf '%s' "${HEALTH_PORT:-9127}"; }
CONTROL_SERVE_PORT="8443"
CONTROL_CAPABILITY="__CAPABILITY__"
CONTROL_API_SOCKET="/run/interstellar-control-api/api.sock"
CONTROL_SERVE_TARGET="unix:${CONTROL_API_SOCKET}"
CONTROL_HELPER_SOCKET="/run/interstellar-control/helper.sock"
CONTROL_API_UNIT="${CONTROL_API_UNIT:-/nonexistent}"
CONTROL_POLICY="${CONTROL_POLICY:-/nonexistent}"
PYTHON_MINIMUM_MAJOR=3
PYTHON_MINIMUM_MINOR=9
PYTHON_MINIMUM="3.9"
""".replace("__CAPABILITY__", CAPABILITY)

# Stub tailscale. `serve --bg` rewrites the recorded config the way the real CLI
# would, so the post-write verification in the Toolbox exercises a real read-back.
TAILSCALE_STUB = r"""#!/usr/bin/env bash
printf '%s\n' "$*" >>"$SERVE_CALLS"
case "$1 $2" in
  "version --daemon")
    echo '{"short":"'"$TS_CLIENT"'","daemonLong":"'"$TS_DAEMON"'"}'; exit 0 ;;
esac
if [[ "$1" == "version" ]]; then echo "$TS_CLIENT"; exit 0; fi
if [[ "$1" == "status" ]]; then
  echo '{"Self":{"DNSName":"'"$TS_HOST"'."}}'; exit 0
fi
if [[ "$1" == "serve" && "$2" == "status" ]]; then
  cat "$SERVE_STATE"; exit 0
fi
if [[ "$1" == "serve" ]]; then
  [[ "${STUB_SERVE_NOOP:-0}" == "1" ]] && exit 0
  shift
  port=443 target="" caps=""
  for arg in "$@"; do
    case "$arg" in
      --bg) ;;
      --https=*) port="${arg#--https=}" ;;
      --accept-app-caps=*) caps="${arg#--accept-app-caps=}" ;;
      *) target="$arg" ;;
    esac
  done
  [[ "$target" =~ ^(unix:|http) ]] || target="http://127.0.0.1:${target}"
  if [[ "$3" == "off" || "$2" == "off" ]]; then exit 0; fi
  python3 - "$SERVE_STATE" "$TS_HOST" "$port" "$target" "$caps" <<'PY'
import json, sys
path, host, port, target, caps = sys.argv[1:6]
try:
    config = json.loads(open(path).read() or "{}")
except ValueError:
    config = {}
web = config.setdefault("Web", {})
handler = {"Proxy": target}
entry = {"Handlers": {"/": handler}}
if caps:
    entry["AcceptAppCaps"] = [caps]
web[f"{host}:{port}"] = entry
config.setdefault("TCP", {})[port] = {"HTTPS": True}
open(path, "w").write(json.dumps(config))
PY
  exit 0
fi
exit 0
"""

SYSTEMCTL_STUB = """#!/usr/bin/env bash
if [[ "$1" == "is-active" ]]; then
  for arg in "$@"; do
    case "$arg" in
      interstellar-control-api) echo "${STUB_API_STATE:-active}"; exit 0 ;;
      interstellar-control-helper) echo "${STUB_HELPER_STATE:-active}"; exit 0 ;;
    esac
  done
  echo active
fi
exit 0
"""


def health_entry(port: int = 9127) -> dict:
    return {"Handlers": {"/": {"Proxy": f"http://127.0.0.1:{port}"}}}


def control_entry(target: str = CONTROL_TARGET, caps: str | None = CAPABILITY) -> dict:
    entry: dict = {"Handlers": {"/": {"Proxy": target}}}
    if caps:
        entry["AcceptAppCaps"] = [caps]
    return entry


class ServeTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self.dir = tempfile.TemporaryDirectory()
        base = Path(self.dir.name)
        self.addCleanup(self.dir.cleanup)
        self.state = base / "serve.json"
        self.calls = base / "calls.log"
        self.state.write_text("{}")
        self.calls.write_text("")
        bindir = base / "bin"
        bindir.mkdir()
        for name, body in (("tailscale", TAILSCALE_STUB), ("systemctl", SYSTEMCTL_STUB)):
            path = bindir / name
            path.write_text(body)
            path.chmod(path.stat().st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)
        self.bindir = bindir
        self.base = base

    def run_shell(self, script: str, *, web: dict | None = None, env: dict | None = None):
        if web is not None:
            self.state.write_text(json.dumps({"Web": web}))
        body = PREAMBLE + "\n".join(extract(name) for name in FUNCTIONS) + "\n" + script
        environment = {
            **os.environ,
            "PATH": f"{self.bindir}:{os.environ['PATH']}",
            "SERVE_STATE": str(self.state),
            "SERVE_CALLS": str(self.calls),
            "TS_HOST": HOST,
            "TS_CLIENT": "1.102.4",
            "TS_DAEMON": "1.102.4-t3caf7d9e7-g084ee3b64",
            **(env or {}),
        }
        return subprocess.run(["bash", "-c", body], capture_output=True, text=True, env=environment)

    def web(self) -> dict:
        return json.loads(self.state.read_text() or "{}").get("Web", {})

    def serve_calls(self) -> list[str]:
        return [line for line in self.calls.read_text().splitlines() if line.startswith("serve --bg")]

    # 1. Health-only Serve: repair must add the :8443 control handler.
    def test_health_only_gains_control_handler(self):
        result = self.run_shell("ensure_control_serve", web={f"{HOST}:443": health_entry()})
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn(f"{HOST}:8443", self.web())
        self.assertEqual(CONTROL_TARGET, self.web()[f"{HOST}:8443"]["Handlers"]["/"]["Proxy"])
        self.assertIn(CAPABILITY, json.dumps(self.web()[f"{HOST}:8443"]))
        # The pre-existing health route is untouched.
        self.assertEqual(health_entry(), self.web()[f"{HOST}:443"])

    # 2. Completely missing Serve: health and control both get configured.
    def test_empty_serve_configures_both(self):
        result = self.run_shell("ensure_health_serve; ensure_control_serve", web={})
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(f"http://127.0.0.1:9127", self.web()[f"{HOST}:443"]["Handlers"]["/"]["Proxy"])
        self.assertEqual(CONTROL_TARGET, self.web()[f"{HOST}:8443"]["Handlers"]["/"]["Proxy"])

    # 3. Correct topology: idempotent, writes nothing.
    def test_correct_state_is_idempotent(self):
        web = {f"{HOST}:443": health_entry(), f"{HOST}:8443": control_entry()}
        result = self.run_shell("ensure_health_serve; ensure_control_serve", web=web)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual([], self.serve_calls(), "an already correct topology must not be rewritten")
        self.assertEqual(web, self.web())

    # 4. Control handler pointing somewhere else is repaired.
    def test_wrong_control_target_is_repaired(self):
        web = {f"{HOST}:443": health_entry(),
               f"{HOST}:8443": control_entry(target="http://127.0.0.1:9999")}
        result = self.run_shell("ensure_control_serve", web=web)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("repairing", result.stdout)
        self.assertEqual(CONTROL_TARGET, self.web()[f"{HOST}:8443"]["Handlers"]["/"]["Proxy"])

    # 5. Missing --accept-app-caps is repaired. This is the state that produces
    #    HTTP 403 for Home Assistant while everything looks healthy locally.
    def test_missing_capability_is_repaired(self):
        web = {f"{HOST}:443": health_entry(), f"{HOST}:8443": control_entry(caps=None)}
        result = self.run_shell("ensure_control_serve", web=web)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("does not accept", result.stdout)
        self.assertIn(CAPABILITY, json.dumps(self.web()[f"{HOST}:8443"]))

    # 6. Tailscale older than 1.98.9 refuses control configuration.
    def test_old_tailscale_refuses_control_serve(self):
        result = self.run_shell("ensure_control_serve || echo REFUSED", web={},
                                env={"TS_CLIENT": "1.98.0", "TS_DAEMON": "1.98.0"})
        self.assertIn("REFUSED", result.stdout)
        self.assertIn("1.98.9 or newer", result.stdout)
        self.assertEqual([], self.serve_calls())
        self.assertNotIn(f"{HOST}:8443", self.web())

    # 7. Unrelated user Serve routes are preserved.
    def test_unrelated_routes_are_preserved(self):
        custom = {"Handlers": {"/": {"Proxy": "http://127.0.0.1:3000"}}}
        web = {f"{HOST}:443": health_entry(), f"{HOST}:9000": custom}
        result = self.run_shell("ensure_control_serve", web=web)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(custom, self.web()[f"{HOST}:9000"])
        self.assertIn(f"{HOST}:8443", self.web())

    # 8. Status must not claim control works just because systemd is active.
    def test_status_reports_missing_serve_with_active_services(self):
        unit = self.base / "unit"
        policy = self.base / "policy.json"
        unit.write_text("")
        policy.write_text("{}")
        result = self.run_shell("control_show_status", web={f"{HOST}:443": health_entry()},
                                env={"CONTROL_API_UNIT": str(unit), "CONTROL_POLICY": str(policy)})
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertRegex(result.stdout, r"API service:\s+active")
        self.assertRegex(result.stdout, r"Helper service:\s+active")
        self.assertRegex(result.stdout, r"Control Serve:\s+missing")
        self.assertRegex(result.stdout, r"Remote control:\s+unavailable")
        self.assertNotIn("Tailnet Grant:   not verifiable", result.stdout)

    def test_status_reports_configured_serve(self):
        unit = self.base / "unit"
        policy = self.base / "policy.json"
        unit.write_text("")
        policy.write_text("{}")
        web = {f"{HOST}:443": health_entry(), f"{HOST}:8443": control_entry()}
        result = self.run_shell("control_show_status", web=web,
                                env={"CONTROL_API_UNIT": str(unit), "CONTROL_POLICY": str(policy)})
        self.assertIn(f"https://{HOST}:8443/", result.stdout)
        self.assertIn("accepted by Serve", result.stdout)
        self.assertIn("not verifiable locally", result.stdout)

    # A successful CLI call is not proof; verify the effective topology.
    def test_silent_serve_failure_is_detected(self):
        result = self.run_shell("ensure_control_serve || echo FAILED", web={},
                                env={"STUB_SERVE_NOOP": "1"})
        self.assertIn("FAILED", result.stdout)
        self.assertIn("did not reach the expected state", result.stdout)

    def test_self_check_separates_local_state_from_authorization(self):
        web = {f"{HOST}:443": health_entry(), f"{HOST}:8443": control_entry()}
        result = self.run_shell("control_self_check", web=web)
        self.assertEqual(0, result.returncode, result.stderr)
        # The runtime section must name the interpreter it actually found.
        self.assertIn("python3 >= 3.9", result.stdout)
        self.assertIn("[✓] Control Serve configured on :8443", result.stdout)
        self.assertIn("[✓] --accept-app-caps configured", result.stdout)
        self.assertIn("[?] Tailnet app capability Grant cannot be proven locally", result.stdout)
        self.assertIn(f"https://{HOST}:8443", result.stdout)

    def test_grant_guidance_targets_port_and_capability(self):
        result = self.run_shell("control_grant_guidance")
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn('"ip": ["tcp:8443"]', result.stdout)
        self.assertIn(CAPABILITY, result.stdout)
        self.assertIn("never edits your tailnet policy", result.stdout)
        self.assertIn(HOST, result.stdout)


class VersionTestCase(unittest.TestCase):
    """One authoritative control version, reported the same way everywhere."""

    def test_control_version_is_consistent(self):
        api = (ROOT / "control/control_api.py").read_text()
        helper = (ROOT / "control/control_helper.py").read_text()
        self.assertIn('VERSION = "0.2.1"', api)
        self.assertIn('VERSION = "0.2.1"', helper)
        # The Server header must derive from VERSION, never a second literal.
        self.assertIn('server_version = f"InterstellarControl/{VERSION}"', api)
        self.assertNotIn('InterstellarControl/0.1', api)

    def test_server_header_is_exact_and_hides_the_runtime(self):
        """The live header read `InterstellarControl/0.1 Python/3.13.5`."""
        spec = importlib.util.spec_from_file_location(
            "control_api_header", ROOT / "control/control_api.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        handler = module.Handler.__new__(module.Handler)
        self.assertEqual("InterstellarControl/0.2.1", handler.version_string())
        self.assertNotIn("Python/", handler.version_string())
        # No trailing whitespace from the default server_version + sys_version join.
        self.assertEqual(handler.version_string(), handler.version_string().strip())

    def test_embedded_toolbox_copy_matches_sources(self):
        for name in ("control_api.py", "control_helper.py"):
            body = (ROOT / "control" / name).read_text().rstrip()
            self.assertIn(body, SOURCE, f"{name} is not embedded verbatim; run scripts/embed-control.py")


if __name__ == "__main__":
    unittest.main()

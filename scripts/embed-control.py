from pathlib import Path
root = Path(__file__).resolve().parents[1]
box = root / 'toolbox/interstellar-network-toolbox.sh'
source = box.read_text()
start = source.index('write_control_helper_python() {')
end = source.index('install_health_agent() {', start)
helper = (root / 'control/control_helper.py').read_text().rstrip()
api = (root / 'control/control_api.py').read_text().rstrip()
block = f'''write_control_helper_python() {{
  install -d -o root -g root -m 0755 "$AGENT_DIR"
  cat >"$CONTROL_HELPER_PY" <<'PYEOF'
{helper}
PYEOF
  chown root:root "$CONTROL_HELPER_PY"
  chmod 0755 "$CONTROL_HELPER_PY"
}}

write_control_api_python() {{
  cat >"$CONTROL_API_PY" <<'PYEOF'
{api}
PYEOF
  chown root:root "$CONTROL_API_PY"
  chmod 0755 "$CONTROL_API_PY"
}}

write_control_helper_unit() {{
  cat >"$CONTROL_HELPER_UNIT" <<'EOF'
[Unit]
Description=Interstellar Network Privileged Control Helper
After=local-fs.target

[Service]
Type=simple
User=root
Group=root
RuntimeDirectory=interstellar-control
RuntimeDirectoryMode=0755
ExecStart=/usr/bin/python3 /usr/local/lib/interstellar/control-helper.py
Restart=on-failure
RestartSec=3
PrivateTmp=yes
UMask=0027

[Install]
WantedBy=multi-user.target
EOF
  chown root:root "$CONTROL_HELPER_UNIT"
  chmod 0644 "$CONTROL_HELPER_UNIT"
}}

write_control_api_unit() {{
  cat >"$CONTROL_API_UNIT" <<'EOF'
[Unit]
Description=Interstellar Network Unprivileged Control API
After=network-online.target interstellar-control-helper.service
Requires=interstellar-control-helper.service

[Service]
Type=simple
User=interstellar-control
Group=interstellar-control
RuntimeDirectory=interstellar-control-api
RuntimeDirectoryMode=0700
ExecStart=/usr/bin/python3 /usr/local/lib/interstellar/control-api.py
Restart=on-failure
RestartSec=3
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ReadWritePaths=/run/interstellar-control-api
ProtectHome=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
ProtectClock=yes
RestrictSUIDSGID=yes
LockPersonality=yes
CapabilityBoundingSet=
AmbientCapabilities=
RestrictAddressFamilies=AF_UNIX
UMask=0077

[Install]
WantedBy=multi-user.target
EOF
  chown root:root "$CONTROL_API_UNIT"
  chmod 0644 "$CONTROL_API_UNIT"
}}

write_control_policy() {{
  local expected="$1" manageable="$2" expected_containers="$3" manageable_containers="$4"
  install -d -o root -g root -m 0755 /etc/interstellar
  python3 - "$CONTROL_POLICY" "$expected" "$manageable" "$expected_containers" "$manageable_containers" <<'PYEOF'
import json, re, sys
from pathlib import Path
name = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.@-]{{0,127}}$")
keys = ("expected_services", "manageable_services", "expected_containers", "manageable_containers")
policy = {{}}
for key, raw in zip(keys, sys.argv[2:]):
    values = list(dict.fromkeys(x.strip() for x in raw.split(",") if x.strip()))
    if any(not name.fullmatch(x) for x in values):
        raise SystemExit(f"Invalid {{key}} target")
    policy[key] = values
policy["sensitive_services_opt_in"] = []
Path(sys.argv[1]).write_text(json.dumps(policy, indent=2) + "\\n")
PYEOF
  chown root:root "$CONTROL_POLICY"
  chmod 0644 "$CONTROL_POLICY"
}}

install_control_plane() {{
  if ! tailscale_control_version_supported; then
    warn "Control installation requires Tailscale 1.98.9 or newer. Health monitoring remains available."
    return 1
  fi
  install_pkg python3
  if ! getent group interstellar-control >/dev/null; then
    groupadd --system interstellar-control
  fi
  if ! getent passwd interstellar-control >/dev/null; then
    useradd --system --gid interstellar-control --shell /usr/sbin/nologin --home-dir /nonexistent interstellar-control
  else
    usermod --gid interstellar-control interstellar-control
  fi
  install -d -o root -g interstellar-control -m 2750 /var/lib/interstellar-control
  local expected manageable expected_containers manageable_containers
  expected="$(agent_env_value INTERSTELLAR_EXPECTED_SERVICES 2>/dev/null || echo ssh,tailscaled)"
  manageable="$(ui_input "Manageable services" "Comma-separated systemd units HA may control. SSH and Tailscale require extra server-side opt-in." "docker")" || return
  expected_containers="$(ui_input "Expected containers" "Comma-separated Docker container names that should run:" "")" || return
  manageable_containers="$(ui_input "Manageable containers" "Comma-separated Docker container names HA may control:" "")" || return
  write_control_policy "$expected" "$manageable" "$expected_containers" "$manageable_containers"
  write_control_helper_python
  write_control_api_python
  write_control_helper_unit
  write_control_api_unit
  systemctl daemon-reload
  systemctl enable interstellar-control-helper interstellar-control-api
  systemctl restart interstellar-control-helper
  systemctl restart interstellar-control-api
  fix "Interstellar control plane v0.2.0 installed."
  info "Configure a tailnet Grant for interstellarnetwork.nl/cap/server-control."
  info "Then run: tailscale serve --bg --https=8443 --accept-app-caps=interstellarnetwork.nl/cap/server-control unix:/run/interstellar-control-api/api.sock"
  info "Add https://YOUR-MAGICDNS-NAME:8443 as the control URL in Home Assistant."
}}

upgrade_control_plane_noninteractive() {{
  [[ -f "$CONTROL_POLICY" && -f "$CONTROL_API_UNIT" ]] || return 0
  if ! tailscale_control_version_supported; then
    warn "Control upgrade paused until Tailscale is 1.98.9 or newer."
    return 1
  fi
  write_control_helper_python
  write_control_api_python
  write_control_helper_unit
  write_control_api_unit
  systemctl daemon-reload
  systemctl restart interstellar-control-helper
  systemctl restart interstellar-control-api
}}

'''
box.write_text(source[:start] + block + source[end:])

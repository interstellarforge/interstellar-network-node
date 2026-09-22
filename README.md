# Interstellar Network node

The root-only `interstellar` toolbox manages Debian and Ubuntu servers. Toolbox 4.5.0 embeds health agent 3.2.0 and control service 0.2.0.

## Install

```bash
curl -fL https://github.com/interstellarforge/interstellar-network-node/releases/latest/download/install.sh -o /tmp/interstellar-install.sh
sudo bash /tmp/interstellar-install.sh
interstellar
```

The toolbox is installed at `/usr/local/sbin/interstellar-toolbox` with mode `0700`. The `/usr/local/bin/interstellar` launcher uses `sudo`. Release downloads are checked against SHA-256 checksums.

## Health and control

The health agent runs with a dynamic unprivileged user and listens only on `127.0.0.1:9127`. It offers GET `/`, `/health`, `/stats`, and `/metrics`. It cannot reboot, install packages, or control services or containers.

The optional control API runs as the dedicated `interstellar-control` user on `/run/interstellar-control-api/api.sock` (mode `0600`, private directory). Tailscale Serve is the only remote entry point. It requires the `interstellarnetwork.nl/cap/server-control` app capability. The separate root helper listens on `/run/interstellar-control/helper.sock` (mode `0660`) and verifies the peer UID. The helper accepts only named actions and root-owned policy targets. It stores a bounded SQLite audit history in `/var/lib/interstellar-control/actions.db` (mode `0640`).

Control requires Tailscale **1.98.9 or newer**. The Toolbox prints the installed CLI, running daemon, and minimum versions and refuses control installation or upgrade if either version is older or unknown. The control API also rejects actions after a downgrade or before a newly upgraded daemon has restarted. Health-only monitoring remains available on older Tailscale versions where Serve works. See [Tailscale’s Serve security bulletin](https://tailscale.com/security-bulletins).

Run `interstellar` → **Interstellar API / Agent** to install or configure both planes. Configure separate Serve listeners for health (default HTTPS port 443) and control (example 8443):

```bash
sudo tailscale serve --bg 9127
sudo tailscale serve --bg --https=8443 \
  --accept-app-caps=interstellarnetwork.nl/cap/server-control \
  unix:/run/interstellar-control-api/api.sock
```

Grant the HA Tailscale identity network access to the control port and that app capability. Keep the control listener on Serve, never Funnel. Read [the HA integration guide](https://github.com/interstellarforge/ha-interstellar-network-server-integration#readme) for card and action details.

`/etc/interstellar/control-policy.json` separates `expected_services` from `manageable_services`, and `expected_containers` from `manageable_containers`. SSH and Tailscale service control also require `sensitive_services_opt_in`. Roles influence display only; they do not add arbitrary service permissions.

Security-only updates fail closed unless the server's `unattended-upgrades` configuration selects only security origins and disables automatic reboot. All package updates use normal `apt-get upgrade`. No control action runs a shell or accepts command strings.

## Wake-on-LAN

Run `interstellar` → **Tailscale & networking** → **Wake-on-LAN**. Select a physical NIC, inspect its MAC and `ethtool` capabilities, then enable magic-packet wake. The Toolbox writes root-owned `/etc/interstellar/wol.json` and enables `interstellar-wol.service`, which reapplies only the validated interface and MAC at boot. The menu can disable WoL or test current state and persistence. Unsupported NICs and virtual machines are reported rather than treated as wake capable.

The health agent reports sanitized `wake_on_lan` metadata, including a broadcast address only when the NIC’s IPv4 configuration provides one. Home Assistant remembers this while the node is offline and sends the magic packet itself. Wake does not use the target control service, and there is no `/actions/wake` route. Home Assistant and the target generally need to share an L2 network; a future allowlisted relay may serve separate networks.

## Releases

Run `./scripts/release.sh 4.5.0` from the node repository for a release. `scripts/embed-control.py` regenerates the toolbox's embedded control sources from `control/*.py`; the release script runs it and verifies the result before tagging.

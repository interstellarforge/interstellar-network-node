# Interstellar Network node

The root-only `interstellar` toolbox manages Debian and Ubuntu servers. Toolbox 4.6.2 embeds health agent 3.2.2 and control service 0.2.1.

## Supported runtime

| Requirement | Minimum | Notes |
| --- | --- | --- |
| Python | **3.9** | Debian 11 and most Proxmox LXC templates ship 3.9. Everything that runs on a node is 3.9-compatible and CI tests against 3.9 and 3.13. |
| OS | Debian 11+ / Ubuntu 20.04+ | Bare metal, VM, or LXC/Docker container. |
| Tailscale | 1.98.9+ | Control plane only; health monitoring works on older versions. |

Installation refuses to proceed on an interpreter older than 3.9 rather than writing code that cannot run. **Interstellar API / Agent → Show status** and **Control plane self-check** both report the detected version.

Containers are supported. Hardware telemetry that a container cannot see — temperature sensors, block devices, physical NIC Wake-on-LAN — is reported as absent rather than treated as a failure, and an LXC or Docker guest is detected even when `systemd-detect-virt` is not installed.

## Install

```bash
curl -fL https://github.com/interstellarforge/interstellar-network-node/releases/latest/download/install.sh -o /tmp/interstellar-install.sh
sudo bash /tmp/interstellar-install.sh
interstellar
```

The toolbox is installed at `/usr/local/sbin/interstellar-toolbox` with mode `0700`. The `/usr/local/bin/interstellar` launcher uses `sudo`. Release downloads are checked against SHA-256 checksums.

## Health and control

The health agent runs with a dynamic unprivileged user and listens only on `127.0.0.1:9127`. It offers GET `/`, `/health`, `/stats`, and `/metrics`. It cannot reboot, install packages, or control services or containers.

A single failing collector no longer removes the whole response. `/stats` keeps returning valid JSON with `"degraded": true` and a `collector_errors` map naming the failed collectors by exception type; `/health` reports `degraded`. Only the exception type is published, since messages can carry filesystem paths and this endpoint is unauthenticated — full detail goes to the journal. If the payload cannot be built at all, the agent answers HTTP 500 with JSON instead of closing the connection.

The optional control API runs as the dedicated `interstellar-control` user on `/run/interstellar-control-api/api.sock` (mode `0600`, private directory). Tailscale Serve is the only remote entry point. It requires the `interstellarnetwork.nl/cap/server-control` app capability. The separate root helper listens on `/run/interstellar-control/helper.sock` (mode `0660`) and verifies the peer UID. The helper accepts only named actions and root-owned policy targets. It stores a bounded SQLite audit history in `/var/lib/interstellar-control/actions.db` (mode `0640`).

Control requires Tailscale **1.98.9 or newer**. The Toolbox prints the installed CLI, running daemon, and minimum versions and refuses control installation or upgrade if either version is older or unknown. The control API also rejects actions after a downgrade or before a newly upgraded daemon has restarted. Health-only monitoring remains available on older Tailscale versions where Serve works. See [Tailscale’s Serve security bulletin](https://tailscale.com/security-bulletins).

Run `interstellar` → **Interstellar API / Agent** to install or configure both planes. Installing or repairing the Control API now configures both Serve listeners itself and verifies the result with `tailscale serve status`. The canonical topology is:

| Plane | URL | Backend |
| --- | --- | --- |
| Health | `https://<magicdns-name>/` | `http://127.0.0.1:9127` |
| Control | `https://<magicdns-name>:8443/` | `unix:/run/interstellar-control-api/api.sock` |

The equivalent manual commands, should you need them:

```bash
sudo tailscale serve --bg 9127
sudo tailscale serve --bg --https=8443 \
  --accept-app-caps=interstellarnetwork.nl/cap/server-control \
  unix:/run/interstellar-control-api/api.sock
tailscale serve status
```

The control handler must carry `--accept-app-caps`. Without it Serve strips the capability header and the control API answers every request with `HTTP 403 {"error":"Tailscale control capability required"}` even though both services are running.

The HA Tailscale identity also needs network access to the control port **and** the app capability. Two menu entries cover this:

- **Show required Tailscale Grant** prints a Grant to merge into your policy by hand.
- **Configure tailnet Grant (Tailscale API)** applies it for you. It shows a diff, has Tailscale validate the result, asks you to type the tailnet name, and writes with an `If-Match` precondition so a concurrent admin-console edit aborts rather than being overwritten. Running it again when the grant exists changes nothing. Your policy file's existing rules, formatting and comments are preserved; if the grant cannot be placed with certainty the Toolbox refuses and prints the snippet instead.

  The credential needs the **`policy_file`** scope (admin console → Settings → Keys). It is passed by environment, never argv, and is never stored on disk.

Keep the control listener on Serve, never Funnel. Read [the HA integration guide](https://github.com/interstellarforge/ha-interstellar-network-server-integration#readme) for card and action details.

**Interstellar API / Agent → Control plane self-check** reports local services, Serve configuration, and tailnet authorization separately. A local check can never prove the tailnet Grant exists, so it says so rather than guessing.

`/etc/interstellar/control-policy.json` separates `expected_services` from `manageable_services`, and `expected_containers` from `manageable_containers`. SSH and Tailscale service control also require `sensitive_services_opt_in`. Roles influence display only; they do not add arbitrary service permissions.

Security-only updates fail closed unless the server's `unattended-upgrades` configuration selects only security origins and disables automatic reboot. All package updates use normal `apt-get upgrade`. No control action runs a shell or accepts command strings.

## Wake-on-LAN

Run `interstellar` → **Tailscale & networking** → **Wake-on-LAN**. Select a physical NIC, inspect its MAC and `ethtool` capabilities, then enable magic-packet wake. The Toolbox writes root-owned `/etc/interstellar/wol.json` and enables `interstellar-wol.service`, which reapplies only the validated interface and MAC at boot. The menu can disable WoL or test current state and persistence. Unsupported NICs and virtual machines are reported rather than treated as wake capable.

The health agent reports sanitized `wake_on_lan` metadata, including a broadcast address only when the NIC’s IPv4 configuration provides one. Home Assistant remembers this while the node is offline and sends the magic packet itself. Wake does not use the target control service, and there is no `/actions/wake` route. Home Assistant and the target generally need to share an L2 network; a future allowlisted relay may serve separate networks.

## Releases

Run `./scripts/release.sh 4.5.0` from the node repository for a release. `scripts/embed-control.py` regenerates the toolbox's embedded control sources from `control/*.py`; the release script runs it and verifies the result before tagging.

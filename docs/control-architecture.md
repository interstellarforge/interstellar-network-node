# Control architecture and security boundary

```text
Home Assistant → Tailscale HTTPS Serve :8443 (Grant + app capability)
               → /run/interstellar-control-api/api.sock (private HTTP Unix socket)
               → unprivileged interstellar-control API
               → /run/interstellar-control/helper.sock (SO_PEERCRED + mode 0660)
               → root helper → fixed systemctl / apt / Docker operations
```

The Toolbox configures both Serve handlers during control install and repair, then re-reads `tailscale serve status` to confirm the effective topology; a zero exit status is not treated as proof. It writes only the Interstellar handlers and never removes unrelated Serve routes. Disabling Interstellar Serve removes `:443` and `:8443` individually rather than running `tailscale serve off`, which would drop everything the node serves.

Three facts are deliberately kept apart, because conflating them cost real debugging time: the control services can be **active**, the control **Serve listener** can still be missing, and the tailnet **Grant** can still be absent. The last one cannot be observed from the node at all. A node whose Serve handler lacks `--accept-app-caps`, or whose tailnet has no matching Grant, answers `403` on every control request while `systemctl` reports everything healthy.

The health plane is separate: Tailscale Serve :443 → `127.0.0.1:9127` → dynamic-user health agent. Its HTTP class implements GET only. It does not import or connect to the control helper. A failed or unconfigured control service does not stop health polling.

Tailscale **1.98.9 or newer** is required for the control plane because of Unix-socket Serve security fixes. The Toolbox refuses control installation/upgrade unless both the CLI and running `tailscaled` daemon meet that version. The API checks both again before POST actions, including after an upgrade that has not restarted the daemon. The health plane can continue on older versions where its TCP-backed Serve works. The control API has no TCP listener. `tailscaled` runs as root on a normal Debian/Ubuntu install and can reach its mode `0600` Unix socket in a mode `0700` runtime directory. Ordinary local users cannot reach it to forge Tailscale headers. Local root remains trusted. The API requires a nonempty JSON `Tailscale-App-Capabilities` entry for `interstellarnetwork.nl/cap/server-control` on control requests. It records `Tailscale-User-Login` when Serve provides it; tagged nodes have a capability but no user login, and are recorded as `tailscale-tagged-node`. Tailnet policy must restrict which users or tagged nodes get the capability and control-port network access. Never use Funnel for control.

The root helper executes one action at a time and bounds its queue to 16. The API process has no root permissions, Docker socket access, or package manager access. The root helper accepts Unix connections only from the `interstellar-control` UID by `SO_PEERCRED`. It validates action IDs, action enum, target syntax, and root-owned policy again. `expected_*` policy is a monitoring rule; `manageable_*` grants control. Even if a sensitive unit is in `manageable_services`, `ssh`, `sshd`, and `tailscaled` need `sensitive_services_opt_in`. The helper does not expose shell, exec, Compose path, or arbitrary argv actions. It resolves allowlisted container names to exact Docker IDs before acting.

Actions progress through `queued` → `running` → `successful` or `failed`. Reboot, shutdown, and control-API restart record `dispatched` before the service can disappear. A reboot becomes `successful` only after a new Linux boot ID is observed; its duration is approximated from dispatch to new boot time. Shutdown remains `dispatched`, including after a later boot, because loss of connectivity does not prove a successful shutdown. A failed `systemctl` call becomes `failed`. The SQLite audit holds the latest 100 actions; the API returns 50. It stores short result/error summaries and never command output. Rejected helper requests with a valid action ID are also recorded as failed. The audit directory is group-readable only by the control API.

## Routes

| Method | Path | Body |
| --- | --- | --- |
| GET | `/` | version and capability presence |
| GET | `/state` | policy, Docker summary, toolbox version, boot time, last reboot action |
| GET | `/actions` | latest 50 records |
| GET | `/actions/{uuid}` | one record |
| POST | `/actions/reboot`, `/actions/shutdown` | `{"confirm_hostname":"atlas"}` |
| POST | `/actions/update/refresh` | `{}` |
| POST | `/actions/update/install` | `{"type":"security"}` or `{"type":"all"}` |
| POST | `/actions/service/{start,stop,restart}` | `{"service":"name"}` |
| POST | `/actions/docker/{start,stop,restart}` | `{"container":"name"}` |
| POST | `/actions/docker/restart-daemon` | `{}` |
| POST | `/actions/tailscale/restart` | `{}` |
| POST | `/actions/interstellar/restart-{health-agent,control-agent,mdns}` | `{}` |

POST success is `202` with an action ID and `queued`. Poll the ID or action list for `running`, `dispatched`, `successful`, or `failed`. A 403/400/404/503 response does not imply an action was submitted.

Wake-on-LAN is separate: Home Assistant sends a UDP magic packet directly to a NIC on its reachable LAN. The health agent only reports WoL metadata. The target control API has no Wake route, since it is offline when Wake is needed. A future relay on an awake Interstellar node could be added with a separate allowlist, but is outside this release.

## Update behavior

`update_refresh` runs `apt-get update`. `update_all` runs normal `apt-get upgrade -y`. `update_security` runs `unattended-upgrade` only after `apt-config dump` shows exclusively security origins and no automatic reboot. The helper returns a failure if the package is missing or configuration is broader. Full-upgrade is deliberately absent. None of these operations request a reboot.

## Deployment checks

Check both sockets and permissions after installation:

```bash
sudo systemctl status interstellar-agent interstellar-control-helper interstellar-control-api
sudo stat -c '%U:%G %a %n' /run/interstellar-control-api /run/interstellar-control-api/api.sock /run/interstellar-control/helper.sock /etc/interstellar/control-policy.json
sudo tailscale serve status
```

A direct connection by an ordinary local user to the API socket should fail. A remote control request without the Grant should get 403. A direct health request for a POST action should get HTTP 501; the health process has no POST handler. Inspect `/actions` for audit results.

Always read `tailscale serve status` before changing Serve. The expected output is:

```text
https://<magicdns-name>
|-- / proxy http://127.0.0.1:9127

https://<magicdns-name>:8443
|-- / proxy unix:/run/interstellar-control-api/api.sock
```

`interstellar` → **Interstellar API / Agent** → **Control plane self-check** checks the same topology and prints the control URL and required capability. `/control` on port 443 is not a supported route; the control plane has only ever been served on its own port, and the Toolbox never configures one.

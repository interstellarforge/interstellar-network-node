# Changelog

## 4.6.2

- Show the response body in **Test /health**, **Test /stats** and **Test /metrics**. They used `curl --fail`, which discards the body of any non-2xx response, so a `/health` 503 that explains itself in JSON arrived as an empty pipe and surfaced only as `Expecting value: line 1 column 1 (char 0)`. The probes now print the status line and the body, and no longer exit the Toolbox when a request fails.
- Explain a degraded host in the response. `/health` now carries `degraded_reasons` naming the failed units, the specific expected services that are not active, collector failures, or the full filesystem, instead of a bare `"status": "degraded"` that forced a trip through `/stats` to guess which rule tripped.
- Stop reporting an unsynchronized clock as degraded inside a container. A container does not own its clock; the host synchronizes it, so `timedatectl` reporting no NTP there is normal rather than a fault.
- Health agent 3.2.2. Keep `/health` and `/stats` answering when a telemetry collector fails. A collector exception used to escape the request handler and close the socket, so callers saw `curl: (52) Empty reply from server` with no explanation while the service still reported `active`. Each collector is now isolated: the response stays valid JSON, carries `"degraded": true` and a `collector_errors` map, and unaffected telemetry is still returned. Only the exception type is published — messages can contain filesystem paths and the endpoint is unauthenticated — with full detail logged to the journal. A total failure returns HTTP 500 with JSON instead of dropping the connection.
- Detect LXC and Docker guests even without `systemd-detect-virt`, via `/run/systemd/container`, PID 1's environment, `/proc/1/cgroup` and `/.dockerenv`. Such hosts previously reported `virtualization: none`, implying hardware and Wake-on-LAN they do not have. Wake-on-LAN now reports explicitly that it does not apply inside a container.
- Cache the host FQDN. `socket.getfqdn()` performs a reverse lookup that blocks for seconds where reverse DNS is slow or unreachable, and it ran on every `/stats` request while Home Assistant polls every 30 seconds.
- Refuse installation and upgrade on Python older than 3.9 instead of writing sources the interpreter cannot run, and report the detected Python version in **Show status** and **Control plane self-check**.
- Add a Python 3.9 compatibility guard covering every runtime source, including the Python embedded in this script, and run the full suite against Python 3.9 and 3.13 in CI. Add health endpoint regression tests that exercise `/`, `/health` and `/stats` over a real socket with the real CPU collector.

## 4.6.1

- Fix `TypeError: zip() takes no keyword arguments` on Python 3.9. `cpu_percentages()` used `zip(..., strict=False)`, which requires Python 3.10, so `/health` and `/stats` failed on Debian 11 and Proxmox LXC guests while `/` and the service status still looked healthy. `strict=False` is the default, so removing it preserves behaviour.

## 4.6.0

- Fix control installation and repair leaving Tailscale Serve unconfigured. The Toolbox printed the `tailscale serve` command and expected the operator to run it, so Atlas and Jupiter ran healthy control services that Home Assistant could never reach. Install and upgrade now configure the health and control Serve handlers idempotently and verify the effective topology with `tailscale serve status` instead of trusting the command's exit status.
- Make `https://<magicdns-name>:8443` → `unix:/run/interstellar-control-api/api.sock` the configured canonical control listener, including `--accept-app-caps=interstellarnetwork.nl/cap/server-control`. A handler that is missing, pointing elsewhere, or missing the capability is repaired; unrelated Serve routes are preserved.
- Stop `tailscale serve off` from removing every route. Disabling Interstellar Serve now removes only the Interstellar handlers, after confirmation.
- Report control status as three separate facts (services, Serve configuration, tailnet Grant) instead of calling control active because systemd is active. Add a **Control plane self-check** and a **Show required Tailscale Grant** menu entry that prints a Grant to merge into your own policy.
- Add **Configure tailnet Grant (Tailscale API)**, which applies the control grant to the tailnet policy file for you. It is never automatic and never silent: it runs only from that menu entry, shows a diff of the exact change, has Tailscale validate the result before anything is written, requires the tailnet name to be typed back, and writes with an `If-Match` precondition so a concurrent admin-console edit aborts the write instead of being overwritten. Re-running it when the grant already exists changes nothing. The grant is inserted textually, so existing rules, formatting and comments in the HuJSON policy survive untouched; if the insertion point cannot be located with certainty the Toolbox refuses and prints the snippet to add by hand. The credential needs the `policy_file` scope, is read from the environment rather than argv, and is never written to disk.
- Health agent 3.2.1: separate `installed`, `api_service_active`, `helper_service_active`, and `serve_expected` from remote authorization, which the agent cannot observe. Detect the control units by their systemd RuntimeDirectory, since both run as `python3` and the previous `/proc` name fallback reported a running control API as inactive.
- Control service 0.2.1: report one authoritative version. The `Server` header was pinned at `InterstellarControl/0.1` while the service was 0.2.0; it now derives from `VERSION` and no longer advertises the Python runtime version.

## 4.5.0

- Require Tailscale 1.98.9 or newer for control installation and action dispatch; health-only monitoring remains separate.
- Add `dispatched` action state, reboot boot-ID reconciliation, approximate duration, and honest shutdown audit state in control service 0.2.0.
- Add physical-NIC Wake-on-LAN configuration, validated persistence, and read-only WoL telemetry in health agent 3.2.0.

## 4.4.0

- Added separate unprivileged control API and root Unix socket helper with server-side action policy and audit.
- Added read-only service policy, Tailscale status, and package version telemetry to health agent 3.1.0.
- Kept health routes GET-only and localhost-only.

## 4.3.0

- Added versioned GitHub Release support and SHA-256 verification.
- Added in-toolbox update checks and health agent refresh.

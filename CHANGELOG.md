# Changelog

## 4.5.1

- Fix control installation and repair leaving Tailscale Serve unconfigured. The Toolbox printed the `tailscale serve` command and expected the operator to run it, so Atlas and Jupiter ran healthy control services that Home Assistant could never reach. Install and upgrade now configure the health and control Serve handlers idempotently and verify the effective topology with `tailscale serve status` instead of trusting the command's exit status.
- Make `https://<magicdns-name>:8443` → `unix:/run/interstellar-control-api/api.sock` the configured canonical control listener, including `--accept-app-caps=interstellarnetwork.nl/cap/server-control`. A handler that is missing, pointing elsewhere, or missing the capability is repaired; unrelated Serve routes are preserved.
- Stop `tailscale serve off` from removing every route. Disabling Interstellar Serve now removes only the Interstellar handlers, after confirmation.
- Report control status as three separate facts (services, Serve configuration, tailnet Grant) instead of calling control active because systemd is active. Add a **Control plane self-check** and a **Show required Tailscale Grant** menu entry that prints a Grant to merge into your own policy; the Toolbox never edits tailnet Access Controls.
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

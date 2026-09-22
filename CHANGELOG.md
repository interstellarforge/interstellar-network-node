# Changelog

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

# Atlas canary deployment

Do this on Atlas before enabling normal shutdown from Home Assistant. Automated tests do not prove Tailscale Serve permissions, host networking, firmware WoL support, or power behavior.

1. On Atlas, run `tailscale version --daemon`. Confirm both Client and Daemon are **1.98.9 or newer**. If it is older, upgrade Tailscale first; health-only monitoring may continue.
2. Install the Toolbox 4.5.0 release, run `sudo interstellar`, upgrade the health agent, and install/upgrade the control plane. Keep manageable services and containers narrowly allowlisted.
3. Verify services and socket permissions:

   ```bash
   sudo systemctl status interstellar-agent interstellar-control-helper interstellar-control-api
   sudo stat -c '%U:%G %a %n' /run/interstellar-control-api /run/interstellar-control-api/api.sock /run/interstellar-control/helper.sock /etc/interstellar/control-policy.json
   sudo tailscale serve status
   ```

4. From the configured HA control URL, verify `GET /state` and `GET /actions` with the HA Tailscale identity. A caller without the Grant must be rejected. Confirm HA still shows health if the control URL is unavailable, with a **Read-only** label.
5. Submit a safe restart of `interstellar-mdns` if installed, or another explicitly manageable harmless test service. Check `queued` → `running` → `successful` and the audit identity. Run apt index refresh and inspect its result. If an allowlisted test container exists, restart it and verify its state.
6. Test reboot **last** among control actions. Confirm `dispatched`, an offline period, then `successful` only after a changed boot ID. Compare the recorded approximate duration with observed downtime.
7. In the Toolbox WoL menu, select Atlas’s physical NIC and confirm `Supports Wake-on` contains `g`, its MAC is correct, and the host is not a VM. Enable WoL. Run the persistence test. Check `/stats` reports `wake_on_lan.enabled`, MAC, interface, and a usable broadcast address; set a broadcast override in HA Options if needed.
8. Reboot Atlas once and verify `ethtool <interface>` still reports `Wake-on: g` and `systemctl is-enabled interstellar-wol.service` reports enabled. Send a Wake packet from HA while Atlas is online only as a packet-path smoke test; this does **not** prove power-on.
9. Arrange console, hypervisor, or physical access. Shut Atlas down in a controlled test. Send `interstellar_network.wake` from HA. Confirm Atlas actually boots, the health coordinator reconnects, and the card changes **Offline → Waking… → Online**. A sent packet alone is not success.
10. Only after step 9 works should shutdown become a normal HA management action. If it fails, keep external start access and investigate firmware, NIC power, broadcast routing, and HA network placement.

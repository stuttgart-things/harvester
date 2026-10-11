# Handoff: sthings-edge (from Claude chat)

Read this first, then `../README.md` (setup steps).

## Context

Bare-metal edge box **sthings-edge** (LattePanda Mu, Intel N100, eMMC) for the office table
tennis setup (Schmetterpause app, Zählwerk score counter, ESP32s). Same box runs in two networks;
the role is detected from the default gateway by `/usr/local/bin/edge-role`
(override: `/etc/edge-role` = `auto|tt|kiosk|none`).

| Network | Router | Subnet / gateway | Role | Runs |
|---|---|---|---|---|
| Table tennis net | GL.iNet Opal GL-SFT1200 (GL fw 4.8.3, OpenWrt 18.06 base) | `192.168.8.0/24`, gw `.1` | `tt` | k3s + Cilium |
| SthingsNet | dd-wrt | `192.168.10.0/24`, gw `.1` | `kiosk` | Firefox kiosk only |

Related repo: `stuttgart-things/harvester` (`docs/edge/architecture.md`, `runbook.md`, `requirements.yaml`)
describes the edge cluster (single-node k3s + Cilium, L2 VIPs, OpenBao, MinIO, Schmetterpause, homerun2).
Local DNS zone for the edge net: `edge.sthings.lab`.

## Box facts

- Ubuntu Server **26.04.1 LTS**, kernel 7.0, `192.168.8.10` via static lease on the Opal
- NICs: `enp1s0` (MAC `00:e0:4c:0a:f6:ff`, DHCP, uplink), `enp2s0` rescue port `10.99.99.1/24` (no gateway, `optional: true`)
- LVM `ubuntu-vg`: `root` → `/` 27G, `home` → `/home` 6.8G, `var` → `/var` 21G (VG fully allocated)
- User `sthings` has passwordless sudo → no `-K` needed
- Control node: Mac, Ansible via Homebrew; inventory group `[edge]`

## Done

1. Network + static lease, netplan with rescue port
2. `sthings.baseos.setup` with `-e manage_filesystem=false`
3. Tools via local `tools.yaml` play + `edge.yaml` profile
4. Kiosk via `kiosk.yaml` — works (tty1 autologin → cage → Firefox via Xwayland)

## Key decisions / gotchas (don't undo)

- **Kiosk = tty1 autologin, not a systemd service.** A service with `PAMName=login` never got `seat0` from logind.
  `getty@tty1` drop-in calls `/usr/local/bin/tty1-getty`, which autologins `kiosk` only in role `kiosk`;
  `~kiosk/.bash_profile` execs `systemd-cat -t kiosk cage -s -- firefox --kiosk <url>`.
- **`MOZ_ENABLE_WAYLAND=0` (Firefox via Xwayland) is required.** Native Wayland crashes cage 0.2.1:
  `wlr_xdg_surface_schedule_configure: Assertion 'surface->initialized' failed`.
- `tty1-getty` waits up to `edge_role_wait_seconds` (30) for a default route in `auto` mode
  (getty starts before DHCP at boot).
- Firefox is the `.deb` from packages.mozilla.org (pin 1000), not the snap. `Sandbox … EPERM` at startup is harmless.
- cage aborts if no monitor is connected (`/sys/class/drm/*/status`).
- `sthings.baseos.manage_filesystem` misdetects bare metal as KVM (`virtualization_type=kvm`, role `host`)
  and doesn't find `mmcblk0` → must stay disabled here.
- Local `tools.yaml` play loads `{{ profile | default('tools') }}.yaml` → always pass `-e profile=edge`
  (otherwise it loads itself). Consider renaming the play to `install-tools.yaml`.

## Open tasks (suggested order)

1. **Collection:** ~~add kiosk play to `stuttgart-things/ansible`~~ done: #1364 (released as
   `sthings-baseos-26.1011.1459`, but without the route wait loop) + #1367 (adds the loop) +
   #1368 (CI: main build checks out the pushed commit; fixes tag collisions on merge bursts).
   Remaining: merge #1368, then #1367, install the new release, switch the box to `sthings.baseos.kiosk`,
   then delete `.claude/kiosk.yaml`.
   Original notes: add `collection-baseos-kiosk.yaml` (playbook `kiosk`) to `stuttgart-things/ansible`
   under `collections/baseos/`. Check how the (Dagger) build collects definition files — separate file
   vs. appending to `binaries.yaml`. Make sure the **latest** version (with the route wait loop) is used.
   Then switch the box to `sthings.baseos.kiosk` and replace the local `kiosk.yaml`.
2. **k3s:** ~~prepare/run~~ installed 2026-10-11 from `../k3s/` (`ok=89 changed=24 failed=0`), reboots in
   auto/kiosk/auto verified -- see `../k3s/README.md`. Next: idempotency run, Flux (own cluster vars).
   Notes from the preparation:
   - k3s 1.35.9 on sqlite + Cilium 1.20.2 / Gateway API v1.6.1 = the tested lab stack (`clusters/edge/k3s`),
     not 1.36.5 as planned earlier (keeps the lab's Flux tree and kubectl v1.35 in `edge.yaml` aligned)
   - sthings.rke has no hook for `node-ip` / Cilium `devices`: k3s picks enp1s0 itself; keep enp2s0 out of
     L2 announcements via the L2 policy `interfaces` when Flux comes (or add a hook to the role)
   - Swap is already off, UFW inactive; `install_kubectl`/`install_helm: false` (edge.yaml owns them)
   - Verify both roles after install: `echo kiosk|tt|auto > /etc/edge-role` + reboot
3. **Bug issue in `stuttgart-things/ansible`** (create via `gh` if not done yet):
   - `container/tools.yaml`: vals `target_version` uses `vcluster_version`; glab `bin_to_copy`/`to_remove` with leading `/bin/glab`; inconsistent `bin_dir`
   - `baseos/binaries.yaml`: mc `source_url` is the source zip, not a binary; gum/gh/task `version_cmd: "-- version"`; jq tag prefix `jq-` breaks Renovate (`extractVersion`)
4. **Enhancement:** `-e tools=a,b,c` filter (set_fact pre_task on `bin`) for `sthings.container.tools` and `sthings.baseos.binaries`
5. **Fix `manage_filesystem`:** only take the KVM path if `virtualization_role == 'guest'`; match `mmcblk*`/`nvme*` disks
6. Later: split `edge_role` into its own playbook/role (useful for headless edge boxes), turn kiosk into a proper role with `defaults/main.yaml`

## Files in this directory

- `../inventory`, `../tools.yaml` (play), `../edge.yaml` (tool profile), `../README.md` (setup steps 1–8)
- `kiosk.yaml` (standalone kiosk play, fallback until the collection release with #1367 is on the box)

# clusters/edge-test2

The **rebuild test** of the single-node edge cluster: a second lab VM,
`edge-tt-test2` in **labul** (Proxmox), set up from scratch by following the
general docs in [`docs/edge`](../../docs/edge/index.md) step by step --
[runbook](../../docs/edge/runbook.md) (*Recreate from scratch*),
[from scratch](../../docs/edge/from-scratch.md) (every hand-written file),
[architecture](../../docs/edge/architecture.md),
[lab testing](../../docs/edge/lab-testing.md). It runs next to `edge-tt-test1` ([`../edge`](../edge/), LabDA),
which stays the reference until this one is accepted (harvester#364).

What it proves:

- the runbook is complete -- every step, in order, on a fresh VM;
- a cluster folder with a different path renders and bootstraps (as the
  LattePanda's will);
- the **persistent secrets** in [`secrets/edge/`](../../secrets/edge/) restore
  everything: same root CA, same OpenBao seal key, same app values;
- OpenBao **self-init** on empty storage (users `terraform` and `admin`, no
  root token);
- the players' side from the catalog (Let's Encrypt via Hetzner DNS) under its
  own public name.

| | `edge-tt-test1` ([`../edge`](../edge/)) | `edge-tt-test2` (this folder) |
|---|---|---|
| Lab | LabDA, vSphere | labul, Proxmox (VM-ID 131) |
| Node | `10.100.136.89` | `10.31.102.144` (DHCP) |
| Gateway VIP / domain | `10.100.136.223` / `*.edge-tt-test1.4sthings.tiab.ssc.sva.de` | `10.31.102.7` / `*.edge-tt-test2.sthings-vsphere.labul.sva.de` |
| Players' VIP / public name | `10.100.136.226` / `*.sthings-edge.com` | `10.31.102.8` / `*.test2.sthings-edge.com` |
| Persistent secrets | `secrets/edge/` | the same |
| OpenBao | initialised by hand (2026-10-04) | self-init |

## Progress

Steps as in the [runbook](../../docs/edge/runbook.md#recreate-from-scratch).

| # | Runbook step | Status |
|---|---|---|
| [1](../../docs/edge/runbook.md#1-address-and-dns) | Address + DNS | done 2026-10-05: labul Clusterbook `10.31.102.7` (`edge-tt-test2`, wildcard DNS) and `.8` (`edge-tt-test2-play`, no DNS); Hetzner `*.test2.sthings-edge.com` → `.8` still to do |
| [2](../../docs/edge/runbook.md#2-vm--base-os) | VM + base OS | done 2026-10-05: Backstage create-vm, stuttgart-things#3474 (merged 17:30, VM Ready 17:39 UTC) |
| [3](../../docs/edge/runbook.md#3-k3s--cilium) | k3s + Cilium | done 2026-10-05: [`k3s/`](./k3s/README.md) -- node Ready 19:27 UTC, verified |
| [4](../../docs/edge/runbook.md#4-persistent-secrets----once-ever) | Persistent secrets | nothing to create -- reused from `secrets/edge/` |
| [5](../../docs/edge/runbook.md#5-flux-files) | Flux files | following [from-scratch.md](../../docs/edge/from-scratch.md) section 2 |
| [6](../../docs/edge/runbook.md#6-flux) | Flux bootstrap | |
| 7 | OpenBao init | nothing to do (self-init) -- to be verified |
| [8](../../docs/edge/runbook.md#8-openbao--minio-configuration) | OpenBao + MinIO config | env file `lab-test2` |
| [10](../../docs/edge/runbook.md#10-verify) | Verify | |

### Step 1 here

Commands (curl or Dagger, reserve vs. assign): [runbook, step
1](../../docs/edge/runbook.md#1-address-and-dns). Used for this cluster:
curl, `reserve` with `10.31.102.7` (`edge-tt-test2`, `ASSIGNED:DNS`,
`*.edge-tt-test2.sthings-vsphere.labul.sva.de`) and `10.31.102.8`
(`edge-tt-test2-play`, `ASSIGNED`). Checked on the node -- a LabDA workstation
does not resolve the labul zones:

```bash
ssh sthings@10.31.102.144 'dig +short schmetterpause.edge-tt-test2.sthings-vsphere.labul.sva.de'   # 10.31.102.7
```

The VM's address comes from DHCP and had belonged to another VM before:
`ssh-keygen -R 10.31.102.144` first, then compare the new host key with the
Proxmox console (`ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`).

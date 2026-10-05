# clusters/edge-test2

The **rebuild test** of the single-node edge cluster: a second lab VM,
`edge-tt-test2` in **labul** (Proxmox), set up from scratch by following the
runbook in [`../edge/README.md`](../edge/README.md) (*Recreate from scratch*),
step by step. It runs next to `edge-tt-test1` ([`../edge`](../edge/), LabDA),
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

| # | Runbook step | Status |
|---|---|---|
| 1 | Address + DNS | done 2026-10-05: Clusterbook labul `10.31.102.7` (`edge-tt-test2`, wildcard DNS) and `.8` (`edge-tt-test2-play`, no DNS -- its name comes from Hetzner). Resolves on the VM; **not from a LabDA workstation** (its resolvers do not know the labul zones) |
| 2 | VM + base OS | done 2026-10-05: Backstage create-vm, stuttgart-things#3474 (merged 17:30, VM Ready 17:39 UTC, `sthings.baseos.setup` succeeded) |
| 3 | k3s + Cilium | [`k3s/`](./k3s/README.md) |
| 4 | Persistent secrets | nothing to create -- reused from `secrets/edge/` |
| 5 | Flux files | `cluster-apps.yaml`, `cluster-vars.yaml`, `infra/ca`, `lab/` → render |
| 6 | Flux bootstrap | |
| 7 | OpenBao init | nothing to do (self-init) |
| 8 | OpenBao + MinIO config | Terraform with a labul env file |
| 10 | Verify | |

### Step 1: two addresses from Clusterbook (labul)

The labul Clusterbook is `clusterbook.infra.sthings-vsphere.labul.sva.de`
(REST on port 80, network `10.31.102`). Its README documents the API
(*List IPs in a network*, *Reserve*, *Reserve a specific IP*). Pick **one** of
the ways below; all end in the same check.

**Two calls, two behaviours.** `reserve` with an `ip` claims that address
**only if it is free** (`409` with the holder if not) -- never overwrites.
`assign` **overwrites** whatever holds the address and withdraws that
cluster's DNS record. Use `reserve` for a specific address; `assign` only on
purpose.

**0. You already know which addresses are free** (e.g. agreed in the team):
reserve them directly with the `curl` calls under a) step 2.

**a) curl**

```bash
C=http://clusterbook.infra.sthings-vsphere.labul.sva.de
# 1. what is free
curl -s $C/api/v1/networks/10.31.102/ips \
  | jq -r '.[] | [.ip, (if .status=="" then "free" else .status end), .cluster] | @tsv'
# 2. claim two free ones: the gateway VIP with wildcard DNS (*.edge-tt-test2.<zone>),
#    the players' VIP without (its public name comes from Hetzner DNS)
curl -s -X POST $C/api/v1/networks/10.31.102/reserve -H 'Content-Type: application/json' \
  -d '{"cluster":"edge-tt-test2","status":"ASSIGNED","create_dns":true,"ip":"10.31.102.7"}'
curl -s -X POST $C/api/v1/networks/10.31.102/reserve -H 'Content-Type: application/json' \
  -d '{"cluster":"edge-tt-test2-play","status":"ASSIGNED","create_dns":false,"ip":"10.31.102.8"}'
# or let Clusterbook pick the next free one: leave out "ip"
```

**b) Dagger** (`github.com/stuttgart-things/dagger/clusterbook`)

```bash
M=github.com/stuttgart-things/dagger/clusterbook@v0.136.0
S=clusterbook.infra.sthings-vsphere.labul.sva.de:80
# 1. what is free
env -u SSH_AUTH_SOCK dagger call -m $M get-network-ips --server $S --network-key 10.31.102 \
  | jq -r '.[] | [.ip, (if .status=="" then "free" else .status end), .cluster] | @tsv'
# 2a. the next free address (never overwrites)
env -u SSH_AUTH_SOCK dagger call -m $M reserve-ip --server $S --network-key 10.31.102 \
  --cluster edge-tt-test2 --create-dns
env -u SSH_AUTH_SOCK dagger call -m $M reserve-ip --server $S --network-key 10.31.102 \
  --cluster edge-tt-test2-play
# 2b. a SPECIFIC address -- assign-ip OVERWRITES a holder: only after 1. showed it free
env -u SSH_AUTH_SOCK dagger call -m $M assign-ip --server $S --network-key 10.31.102 \
  --ip 10.31.102.7 --cluster edge-tt-test2 --status ASSIGNED --create-dns
# what a cluster holds
env -u SSH_AUTH_SOCK dagger call -m $M get-cluster --server $S --cluster-name edge-tt-test2
```

**Check** -- from the VM: a LabDA workstation's resolvers do not know the
labul zones.

```bash
ssh sthings@10.31.102.144 'dig +short schmetterpause.edge-tt-test2.sthings-vsphere.labul.sva.de'   # 10.31.102.7
```

Used for this cluster (2026-10-05): a), `10.31.102.7` (`edge-tt-test2`,
`ASSIGNED:DNS`) and `10.31.102.8` (`edge-tt-test2-play`, `ASSIGNED`).

The VM's address comes from DHCP and had belonged to another VM before:
`ssh-keygen -R 10.31.102.144` first, then compare the new host key with the
Proxmox console (`ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`).

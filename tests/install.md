# Harvester Reinstall Runbook — `harvester.sthings.lab`

Single-node Harvester demo/test cluster in the `sthings.lab` homelab.
This captures the **exact configuration** of the rebuild so it can be reproduced
by any method (TUI wizard, automated `config.yaml`, PXE, or IaC).

> Scope: **clean reinstall, not upgrade.** No VM/Longhorn data is preserved.
> Only network and cluster config is reproduced; VM disks are recreated from scratch.

---

## Version & install method

| Item | Value |
|---|---|
| Product | Harvester (SUSE Virtualization) |
| Version | **v1.8.0** (GA) |
| Topology | Single node, `mode: create` |
| Install method used | **Full ISO → interactive TUI wizard** |
| Full ISO | `https://releases.rancher.com/harvester/v1.8.0/harvester-v1.8.0-amd64.iso` |
| Checksum | `https://releases.rancher.com/harvester/v1.8.0/harvester-v1.8.0-amd64.sha512` |
| Base OS | SL Micro 6.2 |

> For exact embedded component versions (RKE2 / KubeVirt / Longhorn / Rancher),
> see the v1.8.0 release notes: <https://github.com/harvester/harvester/releases/tag/v1.8.0>
> and docs at <https://docs.harvesterhci.io/v1.8>.

ISO verification before flashing:

```bash
curl -fLO https://releases.rancher.com/harvester/v1.8.0/harvester-v1.8.0-amd64.iso
curl -fLO https://releases.rancher.com/harvester/v1.8.0/harvester-v1.8.0-amd64.sha512
sha512sum -c harvester-v1.8.0-amd64.sha512
```

---

## Node identity

| Field | Value |
|---|---|
| `install mode` | `create` |
| `install role` | `default` |
| `hostname` | `harvester` (resolves as `harvester.sthings.lab` via DD-WRT `expand-hosts`) |
| `token` | `Atlan7is` |
| `password` | **set at install** — mandatory in v1.7+, plaintext, not recoverable from old hash |
| SSH keys | supply current workstation pubkey (none were stored in old `/oem`) |

---

## Management network

Single physical uplink, configured as an active-backup bond (single member), **static** addressing.

| Field | Value |
|---|---|
| Interface (NIC) | `enp5s0` |
| MAC (`hwAddr`) | `58:47:ca:7d:34:f0` |
| Bond mode | `active-backup` |
| Bond `miimon` | `100` |
| Method | `static` |
| IP | `192.168.10.110` |
| Subnet mask | `255.255.255.0` (/24) |
| Gateway | `192.168.10.1` |
| DNS | `192.168.10.1` |
| NTP | `0.suse.pool.ntp.org` |
| MTU | `1500` (default) |
| Management VLAN | none (untagged) |

> Note: the node IP `.110` also has a DD-WRT static reservation, so `method: dhcp`
> would also work. Static was chosen to remove the dependency on the reservation.

---

## VIP (cluster access — UI + Kubernetes API)

| Field | Value |
|---|---|
| VIP | `192.168.10.139` *(confirm/adjust — see note)* |
| VIP mode | **static** (recommended) |

> **Decision:** the original install used a **DHCP VIP** (random kube-vip MAC,
> address from the dynamic pool). On rebuild this is fragile — a DHCP VIP cannot be
> pre-reserved on the router (no stable MAC), and the address is not guaranteed back.
>
> **Use a static VIP outside the DHCP dynamic range** (`192.168.10.100–149`).
> Either move it below the pool (e.g. `192.168.10.50`) or shrink the pool so `.139`
> falls outside it. Confirm the actual running value with:
> ```bash
> kubectl get cm vip -n harvester-system -o yaml | yq '.data'
> ```

---

## Cluster-internal CIDRs

Left at **defaults** (blank in the installer). Internal overlay ranges only — they
never touch the `192.168.10.0/24` LAN, so no conflict.

| Field | Default | Notes |
|---|---|---|
| Pod CIDR | `10.52.0.0/16` | |
| Service CIDR | `10.53.0.0/16` | |
| Cluster DNS | `10.53.0.10` | must sit inside the service CIDR |

> Gotcha: the **vm-dhcp-controller addon** also defaults its internal service CIDR to
> `10.53.0.0/16`. Only an issue if you *change* the cluster service CIDR and forget to
> update the addon. Staying on defaults avoids it. (Not in use here — see networking model.)

---

## Disks

⚠️ **Critical:** this host has a Windows disk that must never be selected.

| Disk | Device | Role | Action |
|---|---|---|---|
| Samsung SSD 990 EVO Plus 2TB | `nvme1n1` | **Install + Longhorn (single-disk)** | ✅ SELECT |
| WD_BLACK SN850X 931.5G | `nvme0n1` | NTFS / Windows `Data` volume | ❌ NEVER TOUCH |
| VIRTUAL-DISK 40G/50G | `sda` / `sdb` | scratch / leftover | ❌ ignore |

Install disk selection:

| Field | Value |
|---|---|
| Installation disk | `nvme1n1` (`nvme-Samsung_SSD_990_EVO_Plus_2TB_S7U7NJ0YA04645J`) |
| Data disk | **"Use the installation disk"** (single-disk; OS + Longhorn share `nvme1n1`) |
| Persistent size | `558Gi` |

> In the install confirmation screen, "Use the installation disk" is rendered as
> `data_disk: /dev/nvme1n1` (same path as `device`). **This is correct** for a
> single-disk layout — not a misconfiguration. The remainder of the 2TB after the
> 558Gi `COS_PERSISTENT` partition becomes the Longhorn `HARV_LH_DEFAULT` partition.
>
> Always pin the disk by `/dev/disk/by-id/...` when scripting — `/dev/nvmeXn1`
> enumeration can reorder across reboots.

---

## Networking model (how addressing actually works)

This cluster uses **the simplest possible network layout** — worth understanding before reproducing:

- **Cluster network:** only the built-in `mgmt` (auto-created by the installer). No custom cluster networks.
- **VM network:** a single NAD named `vms`, **untagged**, bridged onto `mgmt-br`.
- **No VlanConfigs** — VM traffic rides the management network directly.
- **No managed DHCP** — the `vm-dhcp-controller` addon is **not** enabled. `ipam: {}`.
- **Addressing source:** **DD-WRT** (the homelab router) hands out all VM and node leases.

The VM network NAD (`vms`) config:

```json
{
  "cniVersion": "0.3.1",
  "name": "vms",
  "type": "bridge",
  "bridge": "mgmt-br",
  "promiscMode": true,
  "ipam": {}
}
```

Labels: `clusternetwork: mgmt`, `type: UntaggedNetwork`, `ready: true`.

> Implication for rebuild: reproducing the **management interface** (above) is what
> makes `mgmt-br` exist; the `vms` NAD then attaches to it and VMs get IPs from DD-WRT.
> There is **nothing** managed-DHCP / IP-pool related to restore.

---

## Router (DD-WRT) — `192.168.10.1`

### LAN / DHCP

| Field | Value |
|---|---|
| Router IP | `192.168.10.1/24` |
| DHCP | enabled, DHCP Server |
| DHCP pool | `192.168.10.100` – `192.168.10.149` (start `.100`, max 50) |
| Lease | 1440 min |

Static lease (keep):

| MAC | Hostname | IP |
|---|---|---|
| `58:47:CA:7D:34:F0` | `harvester` | `192.168.10.110` |

> **VIP placement rule:** the static VIP must be **outside** `192.168.10.100–149`,
> or the router can lease the VIP address to another client. Either use an IP below the
> pool (e.g. `.50`) or shrink the pool (e.g. max users 30 → ends at `.129`, freeing `.130–.149`).

### dnsmasq (DNS for `sthings.lab`)

Additional Options currently set:

```
domain=sthings.lab
expand-hosts
local=/sthings.lab/
address=/infra.sthings.lab/192.168.10.150
```

Recommended addition for the VIP (gives it a stable name + PTR; use a name that does
**not** collide with the `harvester` node lease):

```
host-record=harvester-vip.sthings.lab,192.168.10.139
```

> `No DNS Rebind` is enabled — harmless for the cluster (internal resolution doesn't
> traverse the router), but it will drop public hostnames that resolve to `192.168.10.x`.

---

## Equivalent automated `config.yaml`

For reproducing via **automatic install / PXE** instead of the wizard
(`scheme_version: 1` is stable across recent releases):

```yaml
scheme_version: 1
token: Atlan7is
os:
  hostname: harvester
  ssh_authorized_keys:
    - <workstation-pubkey>
  password: <plaintext-password>      # or a $6$ shadow hash
  ntp_servers:
    - 0.suse.pool.ntp.org
  dns_nameservers:
    - 192.168.10.1
install:
  mode: create
  management_interface:
    interfaces:
      - name: enp5s0
        hwAddr: "58:47:ca:7d:34:f0"   # optional, pins to the NIC
        default_route: true
    method: static
    ip: 192.168.10.110
    subnet_mask: 255.255.255.0
    gateway: 192.168.10.1
    bond_options:
      mode: active-backup
      miimon: 100
  device: /dev/disk/by-id/nvme-Samsung_SSD_990_EVO_Plus_2TB_S7U7NJ0YA04645J
  # data_disk: omitted  -> single-disk (OS + Longhorn share the install disk)
  vip: 192.168.10.139                 # static; ensure outside DHCP pool
  vip_mode: static
  iso_url: https://releases.rancher.com/harvester/v1.8.0/harvester-v1.8.0-amd64.iso
  # pod/service/cluster_dns omitted -> defaults (10.52.0.0/16 / 10.53.0.0/16 / 10.53.0.10)
# system_settings:                    # optional: seed customized Harvester settings at first boot
#   <setting-name>: <value>
```

---

## Post-install restore (config objects)

After the node is up and `mgmt`/management show green:

### 1. Fresh kubeconfig

The host SSH key changes on reinstall — clear the stale entry first:

```bash
ssh-keygen -f ~/.ssh/known_hosts -R 192.168.10.110
scp rancher@192.168.10.110:/etc/rancher/rke2/rke2.yaml ./harvester.kubeconfig
sed -i '' 's#https://127.0.0.1:6443#https://<VIP>:6443#' ./harvester.kubeconfig
export KUBECONFIG=$PWD/harvester.kubeconfig
kubectl get nodes -o wide
```

### 2. VM network — inline (the only networking object to restore)

`mgmt` is auto-created by the installer; VlanConfigs were empty; IP pools/managed DHCP
are not in use. So the **entire** networking restore is this single NAD, defined inline
below — no backup files needed:

```bash
kubectl apply -f - <<'EOF'
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: vms
  namespace: default
  labels:
    network.harvesterhci.io/clusternetwork: mgmt
    network.harvesterhci.io/type: UntaggedNetwork
spec:
  config: '{"cniVersion":"0.3.1","name":"vms","type":"bridge","bridge":"mgmt-br","promiscMode":true,"ipam":{}}'
EOF
```

The controller fills in `network.harvesterhci.io/ready: "true"` and the connectivity
status after apply. (Harvester's UI also adds a cosmetic `network.harvesterhci.io/route`
annotation — optional; the NAD works without it.)

### 3. VM images

VM images here are **upload-type** (a qcow2 blob in Longhorn), not URL-sourced — so they
can't be recreated from a `VirtualMachineImage` YAML alone; the artifact must be rebuilt
and re-imported. Reproduce via **provenance**, not a manifest dump.

**`u26-dev`** — Ubuntu 26 dev base image:

| Field | Value |
|---|---|
| Name / display | `u26-dev` |
| Namespace | `default` |
| Image type | `raw_qcow2` |
| OS type | `linux` |
| Virtual size | 10 Gi |
| Storage class | `harvester-longhorn` |
| Source type | `upload` |
| Encryption | false |
| Built by | Packer — [`stuttgart-things/harvester` → `packer/ubuntu26`](https://github.com/stuttgart-things/harvester/tree/main/packer/ubuntu26) |

Cloud-init (`packer/ubuntu26/users.yaml`) provisions a `sthings` user with passwordless
sudo and the workstation SSH keys baked in — so VMs from this image are SSH-ready with no
Harvester keypair attachment required.

**Reproduce:**
1. Build the qcow2: run the Packer template in `stuttgart-things/harvester/packer/ubuntu26`.
2. Import into Harvester: UI → *Images → Create → Upload* (or `virtctl image-upload`),
   namespace `default`, name `u26-dev`, storage class `harvester-longhorn`.

> Templates (`virtualmachinetemplates` / versions): recreate via UI as needed. Not
> inlined — for a demo cluster they're cheap to rebuild and not worth committing as dumps.

> **Not restored** (intentionally): IP pools / `vmnetcfgs` (managed DHCP not in use),
> Longhorn/VM disk data (wiped), `mgmt` cluster network (auto-created), node-local
> status objects (blockdevices, vlanstatuses, hugepages, etc.).

---

## Verification checklist

```bash
kubectl get nodes -o wide                                          # Ready, IP .110
kubectl get clusternetworks.network.harvesterhci.io mgmt -o yaml | yq '.status'   # ready: True
kubectl get network-attachment-definitions.k8s.cni.cncf.io -A      # vms present
kubectl get cm vip -n harvester-system -o yaml | yq '.data'        # VIP correct & static
kubectl get virtualmachineimages.harvesterhci.io -A                # images -> Active
```

UI/API reachable at `https://<VIP>` (and `https://harvester-vip.sthings.lab` if the DNS record was added).


# sthings-edge/k3s -- k3s + Cilium on the LattePanda

Single-node k3s + Cilium on `sthings-edge` (`192.168.8.10`, role `tt`). Same
stack as the lab node `edge-tt-test1` ([`../../edge/k3s`](../../edge/k3s/README.md),
background and every option: [`docs/edge/k3s.md`](../../../docs/edge/k3s.md)),
and the same Flux tree runs on top (with this box's own cluster vars, [`../README.md`](../README.md), step 9).

**Status: installed 2026-10-11** ([run 1](#run-1-2026-10-11-cli) below), second run 2026-10-12
(`ok=86 changed=7`, only always-changed tasks, k3s not restarted). Kubeconfig: `~/.kube/sthings-edge`.

| File | |
|---|---|
| [`inventory.ini`](./inventory.ini) | `[initial_master_node]` → `sthings-edge` / `192.168.8.10` (the role needs these groups) |
| [`k3s-vars.yaml`](./k3s-vars.yaml) | k3s 1.35.9 on sqlite, Cilium 1.20.2 (cilium-cli 0.20.1), Gateway API v1.6.1, `k8sServiceHost` 192.168.8.10, kubectl/helm left to `../edge.yaml` |
| [`requirements.yaml`](./requirements.yaml) | lab versions (sthings.rke 26.1003.1401, container 26.1002.1398) + sthings.baseos 26.1011.1465 (kiosk with route wait + multi-tab) |

CLIs on the box come from [`../edge.yaml`](../edge.yaml) (kubectl v1.35.0, helm,
k9s, flux 2.9.6, helmfile, cilium-cli, kubectl-slice, sops, age). The k3s run
only adds cilium-cli (same 0.20.1).

## Preconditions (checked 2026-10-11)

- Box in the table tennis network, `edge-role show` → `tt`. k3s.service has the
  drop-in `ExecCondition=/usr/local/bin/edge-role is tt` (sthings.baseos.kiosk):
  in SthingsNet the unit never starts, so never run the install there.
- Swap off (`swapon --show` empty, no swap in fstab). UFW was inactive; the k3s run enables it (see below).
- `/var` 21G (19G free), 7 GiB RAM, 4 cores.
- `enp2s0` (rescue port, `10.99.99.1/24`) is down without a cable. The Cilium
  pod pool `10.42.0.0/16` overlaps none of the box's networks.

## Run

Run from `clusters/sthings-edge`:

```bash
ansible-galaxy collection install -r k3s/requirements.yaml --upgrade

# 1. connection + role
ansible -i k3s/inventory.ini all -b -m shell -a 'edge-role show'     # must print tt

# 2. k3s + Cilium
ansible-playbook -i k3s/inventory.ini sthings.rke.k3s_cluster -e @k3s/k3s-vars.yaml

# 3. kubeconfig
install -m 600 /tmp/kubeconfig-sthings-edge.yaml ~/.kube/sthings-edge && rm /tmp/kubeconfig-sthings-edge.yaml
export KUBECONFIG=~/.kube/sthings-edge
kubectl get nodes -o wide                  # Ready, v1.35.9+k3s1, INTERNAL-IP 192.168.8.10
ssh sthings@192.168.8.10 sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml cilium status   # all OK
```

`--upgrade` matters: an older `sthings.rke` already in `~/.ansible/collections`
silently ignores `cilium_chart_version` and `k3s_cluster_init`.

After the install, check both roles:

```bash
echo kiosk | sudo tee /etc/edge-role && sudo reboot    # k3s inactive (condition failed), kiosk on tty1
echo tt    | sudo tee /etc/edge-role && sudo reboot    # k3s active, normal login on tty1
echo auto  | sudo tee /etc/edge-role
```

## Run 1: 2026-10-11, CLI

ansible-core 2.18 (Homebrew) on the Mac, collections from `requirements.yaml`
(sthings.rke 26.1003.1401, baseos 26.1011.1463), box in the table tennis network (`tt`).

| | Result |
|---|---|
| Run | 19:07:38 → 19:12:22 UTC, `ok=89 changed=24 failed=0` |
| Node | `sthings-edge` Ready, **v1.35.9+k3s1**, containerd 2.2.7-k3s1, Ubuntu 26.04.1, 7.0.0-38, INTERNAL-IP `192.168.8.10` |
| Cilium | Helm `1.20.2`, `cilium status` OK (agent, operator, envoy). `kube-proxy-replacement=true`, `enable-l2-announcements=true`, `enable-gateway-api=true`, pool `10.42.0.0/16` |
| Gateway API | 10 CRDs, bundle-version `v1.6.1`; GatewayClass `cilium` Accepted |
| Datastore | sqlite (`/var/lib/rancher/k3s/server/db/state.db`), `cluster-init: False` |
| Storage | `local-path` (default) |
| Pods | 6/6 Running (cilium, cilium-envoy, cilium-operator, coredns, local-path-provisioner, metrics-server) |
| CLIs | unchanged from `../edge.yaml`: kubectl v1.35.0 and helm v4.3.0 in `/usr/local/bin`; cilium-cli 0.20.1 in `/usr/bin` |

**Role switch, three reboots:**

| `/etc/edge-role` | k3s | tty1 |
|---|---|---|
| `auto` (→ `tt`) | active, node Ready, 6/6 pods | getty login prompt |
| `kiosk` | `Skipped due to 'exec-condition'` | `kiosk` autologin on seat0, cage + Firefox |
| `auto` again | active, Ready, 6/6 pods, `cilium status` OK | getty login prompt |

**UFW is active now.** baseos/`configure_rke_node` enables it with an allow list:
22, 443, 2376, 2379-2380, 6443, 8443, 9099, 9100, 9345, 9443, 9796, 10250, 10252,
10254, 30000-33000/tcp. There is **no rule for 80/tcp** (same as the lab node), and none is
needed: Cilium handles the VIPs' traffic in eBPF before UFW sees it -- checked 2026-10-12,
`http://schmetterpause.edge.sthings.lab/` answers 301 → https on `edge-gateway` (`192.168.8.20`).

**kubectl from the Mac:** `nc -z 192.168.8.10 6443` worked, but the Homebrew `kubectl` got
`connect: no route to host`. Most likely macOS Local Network privacy blocking the binary
(not verified); the cluster itself answers. Fix: System Settings → Privacy & Security → Local Network → allow the
terminal app, then retry. Until then use `kubectl` on the box
(`sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl …`).

**Run 2, 2026-10-12 (idempotency):** `ok=86 changed=7 failed=0`. Changed: `Update apt-cache` (2×),
`Set filesystem watchers`, `Add external ip to kubeconfig`, `Apply Gateway API CRDs (server-side)`,
`Upgrade cilium configuration`, `Fetch kubeconfig` -- all report changed on every run; k3s was not
restarted, the fetched kubeconfig was identical.

## Open points

- **No `node-ip` / Cilium `devices` in sthings.rke.** Neither `k3s-config.yaml.j2`
  nor `cilium-config.yaml.j2` has a hook (still true in sthings.rke 26.1011.1456).
  - k3s takes the address of the default route interface, which is `enp1s0` / `192.168.8.10`.
  - Cilium auto-detects devices, and once a cable is in `enp2s0`, the rescue port is one of them.
  - The flux `cilium-lb` L2 policy has no `interfaces` field, so the VIPs are announced there too:
    stuttgart-things/flux#678 (`CILIUM_L2_INTERFACES: ^enp1s0$` once it exists).

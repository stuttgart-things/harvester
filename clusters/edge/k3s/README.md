# clusters/edge/k3s -- k3s + Cilium on the edge node

How the edge node gets its Kubernetes: `sthings.rke.k3s_cluster` against a host
whose base OS is already done. **Flux never reads this folder.**
[`../.sourceignore`](../.sourceignore) excludes it, and
[`../kustomization.yaml`](../kustomization.yaml) lists only the Flux objects.

| File | |
|---|---|
| [`inventory.ini`](./inventory.ini) | the node, in the cluster layout the role needs (`[initial_master_node]` / `[additional_master_nodes]`) |
| [`k3s-vars.yaml`](./k3s-vars.yaml) | the extra vars: k3s 1.35.9 on sqlite, Cilium 1.20.2 (cilium-cli 0.20.1), Gateway API v1.6.1 |
| [`requirements.yaml`](./requirements.yaml) | the collections: sthings.rke / baseos **26.1003.1399**, pinned for this run |

> **Status: run 1 (CLI) done on 2026-10-03, green, and idempotent on a second
> run. Run 2 (Dagger) is next.** Results: [Last run](#last-run-2026-10-03-cli).

## The node

| | |
|---|---|
| Test VM | `edge-tt-test1` / `10.100.136.89`, LabDA vSphere, Ubuntu 26.04 (`sthings-u26`), 8 vCPU / 15Gi / 128Gi |
| How it was built | Backstage `request-vm` (stuttgart-things#3415) → Dapr worker on `cicd-machinery-test5` → `create-terraform-vm` build PR (#3418): Terraform + `sthings.baseos.setup` |
| Later | the LattePanda Mu: same files, different address in `inventory.ini` |

What the role does on k3s without being told (`k3s_config` defaults): flannel
`none`, kube-proxy and network policy disabled, servicelb and traefik disabled.
local-path stays and is the default StorageClass. Cilium gets
kubeProxyReplacement, Gateway API (+ ALPN, appProtocol), L2 announcements and a
10.42.0.0/16 cluster pool, with `k8sServiceHost` = the node's default IPv4.

## Run 1: Ansible CLI

Prerequisites, once per workstation:

```bash
# ansible-core >= 2.19: the node runs Python 3.14 (Ubuntu 26.04); 2.17 does not
# support targets beyond 3.12
~/ansible-venv/bin/pip install --upgrade "ansible==14.4.0"      # -> ansible-core 2.21.4
~/ansible-venv/bin/ansible-galaxy collection install -r clusters/edge/k3s/requirements.yaml --upgrade
~/ansible-venv/bin/ansible-galaxy collection list | grep sthings  # rke + baseos 26.1003.1399
```

`--upgrade` matters: without it, an older `sthings.rke` already in
`~/.ansible/collections` is kept. That older collection silently ignores
`cilium_chart_version` and `k3s_cluster_init`. The run still goes green, but
with the cli-default Cilium (1.19.x) and embedded etcd.

Access: key-based SSH as `sthings`, NOPASSWD sudo (the VM template sets both).
The repo's [`ansible.cfg`](../../../ansible.cfg) sets `become_ask_pass = True`,
which the run overrides with `ANSIBLE_BECOME_ASK_PASS=False`.

```bash
cd ~/projects/harvester
export EDGE_KEY=~/.ssh/id_ed25519_edge      # whichever key is on the node

# 0. baseos updated the kernel ("System restart required"): reboot first, so
#    k3s and Cilium start on the final kernel
ssh -i $EDGE_KEY sthings@10.100.136.89 sudo reboot

# 1. connection + facts
~/ansible-venv/bin/ansible -i clusters/edge/k3s/inventory.ini all \
  --private-key $EDGE_KEY -m ansible.builtin.setup -a 'filter=ansible_distribution*'

# 2. k3s + Cilium
ANSIBLE_BECOME_ASK_PASS=False ~/ansible-venv/bin/ansible-playbook \
  -i clusters/edge/k3s/inventory.ini --private-key $EDGE_KEY \
  sthings.rke.k3s_cluster \
  -e @clusters/edge/k3s/k3s-vars.yaml

# 3. kubeconfig: the role fetches it to /tmp/kubeconfig, server already the node IP
cp /tmp/kubeconfig ~/.kube/edge-tt-test1
```

## Verify

```bash
export KUBECONFIG=~/.kube/edge-tt-test1
kubectl get nodes -o wide                       # one node, v1.35.9+k3s1
kubectl -n kube-system get ds                   # cilium, cilium-envoy; no kube-proxy
kubectl -n kube-system get pods                 # all Running
cilium status && cilium version                 # cilium image (running): v1.20.2
kubectl get crd gateways.gateway.networking.k8s.io \
  -o jsonpath='{.metadata.annotations.gateway\.networking\.k8s\.io/bundle-version}'   # v1.6.1
kubectl get gatewayclass                        # cilium, Accepted
kubectl get storageclass                        # local-path (default)
ssh -i $EDGE_KEY sthings@10.100.136.89 sudo ls /var/lib/rancher/k3s/server/db   # state.db (sqlite), no etcd/
```

**Idempotency:** run step 2 a second time. Expected: no k3s restart (the role
re-runs the install script only on a version/config change), `cilium upgrade`
instead of `install`, Cilium stays 1.20.2, and the Gateway API CRDs report `ok`.

## Run 2: Dagger

The same playbook, vars, inventory and requirements, through
blueprints/vm `execute-ansible`. It runs the Ansible container instead of the
local venv. That module authenticates with **username + password**, not a key.

The password comes from a file (mode 600, created by hand, never in a command,
the environment or a log). Dagger reads it with `file:` and masks it in the
output -- and every other occurrence of a secret's value too: the user
`sthings` shows up as `***` (`***.rke.install_requirements`).

```bash
cd ~/projects/harvester
install -m 600 /dev/null ~/.edge-tt-test1.pass   # then write the node's sthings password into it

SSH_USER=sthings dagger call -m github.com/stuttgart-things/blueprints/vm@v3.9.0 \
  execute-ansible \
  --src ./clusters/edge/k3s \
  --playbooks sthings.rke.k3s_cluster \
  --inventory ./clusters/edge/k3s/inventory.ini \
  --parameters-file ./clusters/edge/k3s/k3s-vars.yaml \
  --requirements ./clusters/edge/k3s/requirements.yaml \
  --ssh-user env:SSH_USER \
  --ssh-password file:$HOME/.edge-tt-test1.pass \
  --progress plain

shred -u ~/.edge-tt-test1.pass
```

`--requirements` is not optional here. Without it, the module renders the
ansible repo's `templates/requirements-data.yaml` from `main` (since
stuttgart-things/ansible#1307 that is also 26.1003.1399, but this keeps the
run pinned to what this repo says).

Against a node that run 1 already set up, this is the idempotency test through
a second toolchain. Expect the same result.

## Last run: 2026-10-05, Dagger (run 2)

blueprints/vm v3.9.0 `execute-ansible` (ansible-core 2.21.4 in the container),
collections from `requirements.yaml` (sthings.rke **26.1003.1401**, with the
deploy-configure-rke#44 fix; baseos 26.1003.1399), against the running
`edge-tt-test1` -- Flux and all 38 Kustomizations on it.

| | Result |
|---|---|
| Run | 05:42 → 05:49 UTC, `ok=107 changed=5 failed=0` |
| changed | apt cache update (2x), `sysctl fs.inotify.max_user_watches` (a command), `cilium upgrade` (same 1.20.2 and values: Helm revision 4, no pod restarted), kubeconfig fetch into the container -- all tasks that always report changed |
| After | node Ready v1.35.9+k3s1, Cilium v1.20.2, kube-system 6/6 Running, 38/38 Kustomizations Ready |

So run 1 (CLI) and run 2 (Dagger) converge on the same node: the
idempotency test through a second toolchain passed.

## Run 1: 2026-10-03, CLI

`~/ansible-venv` ansible 14.4.0 / core 2.21.4, collections from
`requirements.yaml` (sthings.rke 26.1003.1399), against `edge-tt-test1` after the
reboot onto kernel 7.0.0-38.

| | Result |
|---|---|
| Run 1 | 10:27 → 10:33 UTC, `ok=128 changed=35 failed=0` |
| Node | `edge-tt-test1.tiab.labda.sva.de` Ready, **v1.35.9+k3s1**, containerd 2.2.7-k3s1, Ubuntu 26.04.1, 7.0.0-38 |
| Cilium | Helm `cilium-1.20.2`, image `v1.20.2`, `cilium status` all OK; DaemonSets cilium + cilium-envoy, no kube-proxy |
| cilium-config | `kube-proxy-replacement=true`, `enable-gateway-api(-alpn/-app-protocol)=true`, `enable-l2-announcements=true`, `ipam=cluster-pool`, `10.42.0.0/16`; Helm `k8sServiceHost: 10.100.136.89` |
| Gateway API | 10 CRDs, `bundle-version v1.6.1`, channel `standard`; GatewayClass `cilium` Accepted |
| Datastore | `/var/lib/rancher/k3s/server/db/state.db` (sqlite); `k3s-config.yaml` has `cluster-init: False` |
| Storage | `local-path` (default) |
| Pods | 6/6 Running (cilium, cilium-envoy, cilium-operator, coredns, local-path-provisioner, metrics-server) |
| kubeconfig | `/tmp/kubeconfig`, `server: https://10.100.136.89:6443` |

**Idempotency (run 1 again):** `ok=109 changed=7 failed=0`. k3s was **not
restarted**: `ActiveEnterTimestamp` stayed 10:31:38 UTC before and after. Cilium
took the upgrade path (Helm revision 2 → 3), still 1.20.2. The 7 `changed` tasks:

- `Update apt-cache` (2×) and `Set filesystem watchers`: report changed on every
  run, harmless.
- `Upgrade cilium configuration`: by design; it always runs `cilium upgrade`.
- `Generate self-signed certificate` + `Create cert-manager namespace and
  secret`: **a new root CA on every run.** Nothing here uses that CA (the infra
  bundle builds its own chain in cert-manager), but it is not idempotent.
  **Fixed in sthings.rke 26.1003.1401** (deploy-configure-rke 2026.10.03-2,
  stuttgart-things/deploy-configure-rke#44): the role keeps an existing
  `root-ca.pem` and applies the secret idempotently, and `k3s_cluster` now sets
  `create_root_cert: false`, so this play skips the block entirely.

**UFW:** baseos/`configure_rke_node` leaves UFW active with an allow list
(22, 443, 6443, 8472/udp, 30000-33000, ...). It has no rule for 80/tcp, nor for
Cilium health 4240 / hubble 4244. `cilium status` is OK on a single node.
Whether the Gateway VIP on 80 is reachable through UFW is checked with the first
HTTPRoute.

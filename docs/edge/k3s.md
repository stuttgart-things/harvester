# Edge cluster -- k3s + Cilium

Runbook step 3 in full: how an edge node gets its Kubernetes -- every file and
every command. `sthings.rke.k3s_cluster` (role deploy-configure-rke) against a
host whose base OS is done (`sthings.baseos.setup`). The files live in the
cluster folder, `clusters/<cluster>/k3s/`, and **Flux never reads them**
(`.sourceignore`). Back to the [runbook](./runbook.md).

## What you get

| | |
|---|---|
| k3s | `v1.35.9+k3s1`, single node, **sqlite/kine** (no embedded etcd: one node that never grows, less RAM, fewer writes on the eMMC; not changeable in place later) |
| Off by the role's defaults | flannel, kube-proxy, network policy, servicelb, traefik |
| Kept | `local-path` -- the default StorageClass |
| Cilium | 1.20.2 (the first line tested with k8s 1.35), installed by cilium-cli 0.20.1: kube-proxy replacement, Gateway API (+ ALPN, appProtocol), L2 announcements, cluster pool `10.42.0.0/16`, `k8sServiceHost` = the node's default IPv4 |
| Gateway API | CRDs v1.6.1 (standard), applied server-side; GatewayClass `cilium`. Moving to v1.6.x is one-way |
| Kubeconfig | fetched by the role to `fetched_kubeconfig_path` on the **Ansible controller**, server already the node's address |

## The files

From the repo root, for a new cluster folder:

```bash
CLUSTER=edge-test2            # clusters/$CLUSTER
NODE_IP=10.31.102.144         # the node's address
mkdir -p clusters/$CLUSTER/k3s
```

### `clusters/$CLUSTER/k3s/inventory.ini`

The cluster layout, not a plain `[all]`: the role branches on these two groups,
and an `[all]`-only inventory dies on an undefined group before doing anything.

```bash
cat > clusters/$CLUSTER/k3s/inventory.ini <<EOF
# The edge node. Cluster layout, not [all]: sthings.rke's role branches on these groups.
[initial_master_node]
$NODE_IP

[additional_master_nodes]

[all:vars]
ansible_user=sthings
EOF
```

### `clusters/$CLUSTER/k3s/k3s-vars.yaml`

The extra vars, used as-is by both runs (`-e @k3s-vars.yaml` /
`--parameters-file`):

```bash
cat > clusters/$CLUSTER/k3s/k3s-vars.yaml <<EOF
---
# Extra vars for sthings.rke.k3s_cluster on an edge node (docs/edge/k3s.md).
# Needs sthings.rke >= 26.1003.1399: older collections silently ignore
# cilium_chart_version and k3s_cluster_init.

# LVM is baseos' job; a k3s run never touches the disks.
manage_filesystem: false

install_k3s: true
k3s_state: present
k3s_k8s_version: 1.35.9
k3s_release_kind: k3s1
# sqlite/kine instead of embedded etcd -- decided before the first install.
k3s_cluster_init: false

cluster_setup: singlenode
cluster_name: $CLUSTER

# Cilium 1.20.2 via cilium-cli 0.20.1; needs Gateway API v1.6.1.
install_cilium: true
cilium_version: 0.20.1
cilium_chart_version: "1.20.2"
cilium_gateway_api_crds_version: v1.6.1

prepare_rancher_ha_nodes: true
install_helm_diff: false
# on the Ansible controller: your machine (CLI) or the Dagger container
fetched_kubeconfig_path: /tmp/kubeconfig-$CLUSTER.yaml
EOF
```

### `clusters/$CLUSTER/k3s/requirements.yaml`

The collections, pinned per cluster so a run does not move when the repo-wide
`requirements.yaml` does. Used by both runs (`ansible-galaxy … -r` /
`--requirements`):

```bash
cat > clusters/$CLUSTER/k3s/requirements.yaml <<'EOF'
---
# Collections for the k3s install on an edge node (docs/edge/k3s.md).
# sthings.rke >= 26.1003.1399 (cilium_chart_version, k3s_cluster_init);
# 26.1003.1401 also keeps the role's root CA idempotent
# (deploy-configure-rke#44). Install with --upgrade.
collections:
  - name: community.crypto
    version: 3.4.0
  - name: community.general
    version: 13.4.0
  - name: ansible.posix
    version: 2.2.2
  - name: kubernetes.core
    version: 6.6.0
  - name: community.docker
    version: 5.3.0
  - name: community.vmware
    version: 7.0.0
  - name: awx.awx
    version: 24.6.1
  - name: community.hashi_vault
    version: 7.1.0
  - name: ansible.netcommon
    version: 8.7.1
  - name: https://github.com/stuttgart-things/ansible/releases/download/sthings-baseos-26.1003.1399/sthings-baseos-26.1003.1399.tar.gz
  - name: https://github.com/stuttgart-things/ansible/releases/download/sthings-rke-26.1003.1401/sthings-rke-26.1003.1401.tar.gz
  - name: https://github.com/stuttgart-things/ansible/releases/download/sthings-container-26.1002.1398/sthings-container-26.1002.1398.tar.gz
EOF
```

Newer releases: [stuttgart-things/ansible releases](https://github.com/stuttgart-things/ansible/releases)
(`sthings-rke-*`, `sthings-baseos-*`).

## Before the run

- **Host key.** A DHCP address that belonged to another VM before:
  `ssh-keygen -R $NODE_IP`, then compare the new key with the console
  (`ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`).
- **Kernel.** If base OS updated it ("System restart required",
  `/var/run/reboot-required`), reboot first so k3s and Cilium start on the
  final kernel: `ssh sthings@$NODE_IP sudo reboot`.
- **Access.** `sthings` with NOPASSWD sudo (the VM templates set it): a key for
  the CLI run, the password for the Dagger run.

## Run -- pick one

| | A) Ansible CLI | B) Dagger |
|---|---|---|
| Runs on | your workstation's venv | a container (`blueprints/vm`) |
| SSH | your key | user + password from a file |
| Kubeconfig | lands on your machine | exported out of the container |

### A) Ansible CLI

Once per workstation. ansible-core >= 2.19: the node runs Python 3.14 (Ubuntu
26.04), which 2.17 does not support.

```bash
~/ansible-venv/bin/pip install --upgrade "ansible==14.4.0"      # -> ansible-core 2.21.4
~/ansible-venv/bin/ansible-galaxy collection install -r clusters/$CLUSTER/k3s/requirements.yaml --upgrade
~/ansible-venv/bin/ansible-galaxy collection list | grep sthings  # rke 26.1003.1401
```

`--upgrade` matters: without it an older `sthings.rke` already in
`~/.ansible/collections` is kept, silently ignores `cilium_chart_version` and
`k3s_cluster_init`, and the run still goes green -- with the cli-default
Cilium and embedded etcd.

The repo's `ansible.cfg` sets `become_ask_pass = True`; the run overrides it.

```bash
export EDGE_KEY=~/.ssh/id_ed25519           # whichever key is on the node

# 1. connection + facts
~/ansible-venv/bin/ansible -i clusters/$CLUSTER/k3s/inventory.ini all \
  --private-key $EDGE_KEY -m ansible.builtin.setup -a 'filter=ansible_distribution*'

# 2. k3s + Cilium
ANSIBLE_BECOME_ASK_PASS=False ~/ansible-venv/bin/ansible-playbook \
  -i clusters/$CLUSTER/k3s/inventory.ini --private-key $EDGE_KEY \
  sthings.rke.k3s_cluster \
  -e @clusters/$CLUSTER/k3s/k3s-vars.yaml

# 3. the kubeconfig
install -m 600 /tmp/kubeconfig-$CLUSTER.yaml ~/.kube/$CLUSTER && rm /tmp/kubeconfig-$CLUSTER.yaml
grep server: ~/.kube/$CLUSTER                 # https://<node>:6443
```

### B) Dagger

`blueprints/vm` `execute-ansible-with-export`: the same playbook, vars,
inventory and requirements in the Ansible container. It authenticates with
**user + password**. The password comes from a file (mode 600, created by
hand, never in a command, the environment or a log); Dagger masks it in the
output -- and every other secret value too, so the user `sthings` shows up as
`***` (`***.rke.install_requirements`).

```bash
# 1. the node's sthings password into a file
install -m 600 /dev/null ~/.$CLUSTER.pass
nano ~/.$CLUSTER.pass

# 2. k3s + Cilium; --export-paths copies the fetched kubeconfig out of the
#    container (by file name), `export --path` writes it to the host
export SSH_USER=sthings
env -u SSH_AUTH_SOCK dagger call -m github.com/stuttgart-things/blueprints/vm@v3.10.0 \
  execute-ansible-with-export \
  --src ./clusters/$CLUSTER/k3s \
  --playbooks sthings.rke.k3s_cluster \
  --inventory ./clusters/$CLUSTER/k3s/inventory.ini \
  --parameters-file ./clusters/$CLUSTER/k3s/k3s-vars.yaml \
  --requirements ./clusters/$CLUSTER/k3s/requirements.yaml \
  --ssh-user env:SSH_USER \
  --ssh-password file:$HOME/.$CLUSTER.pass \
  --export-paths /tmp/kubeconfig-$CLUSTER.yaml \
  export --path /tmp/$CLUSTER-k3s 2>&1 | tee /tmp/k3s-$CLUSTER.log

shred -u ~/.$CLUSTER.pass
grep -A2 'PLAY RECAP' /tmp/k3s-$CLUSTER.log   # failed=0

# 3. the kubeconfig
install -m 600 /tmp/$CLUSTER-k3s/kubeconfig-$CLUSTER.yaml ~/.kube/$CLUSTER && rm -rf /tmp/$CLUSTER-k3s
grep server: ~/.kube/$CLUSTER                 # https://<node>:6443
```

- `--requirements` is not optional: without it the module renders the ansible
  repo's `templates/requirements-data.yaml` from `main`.
- `env -u SSH_AUTH_SOCK`: a stale agent socket makes Dagger fail with
  `failed to list SSH agent identities`.
- **Plain `execute-ansible`** (no `-with-export`) loses the kubeconfig: the
  fetch task reports *changed*, into the container's `/tmp`, which is gone
  afterwards. Then take it from the node -- k3s writes `127.0.0.1`:

  ```bash
  ssh sthings@$NODE_IP sudo cat /etc/rancher/k3s/k3s.yaml \
    | sed "s/127.0.0.1/$NODE_IP/" > ~/.kube/$CLUSTER && chmod 600 ~/.kube/$CLUSTER
  ```

## Verify

```bash
export KUBECONFIG=~/.kube/$CLUSTER
kubectl get nodes -o wide                       # Ready, v1.35.9+k3s1
kubectl -n kube-system get pods                 # cilium, cilium-envoy, cilium-operator, coredns, local-path-provisioner, metrics-server -- all Running
kubectl -n kube-system get ds                   # cilium, cilium-envoy; no kube-proxy
kubectl -n kube-system get ds cilium -o jsonpath='{.spec.template.spec.containers[0].image}'   # quay.io/cilium/cilium:v1.20.2
kubectl -n kube-system get cm cilium-config -o json \
  | jq -r '.data | {"kube-proxy-replacement","enable-gateway-api","enable-l2-announcements","cluster-pool-ipv4-cidr"}'
kubectl get crd gateways.gateway.networking.k8s.io \
  -o jsonpath='{.metadata.annotations.gateway\.networking\.k8s\.io/bundle-version}'   # v1.6.1
kubectl get gatewayclass cilium                 # Accepted
kubectl get storageclass                        # local-path (default)
ssh sthings@$NODE_IP sudo ls /var/lib/rancher/k3s/server/db   # state.db (sqlite), no etcd/
```

## Idempotency

A second run (either way) changes nothing that matters: k3s is **not
restarted** (the role re-runs the install script only on a version or config
change), Cilium takes the `cilium upgrade` path with the same version and
values (a new Helm revision, no pod restart), the Gateway API CRDs report
`ok`. Tasks that report *changed* on every run, harmless: `Update apt-cache`
(2×), `Set filesystem watchers` (a command), `Upgrade cilium configuration`,
and the kubeconfig fetch. With sthings.rke < 26.1003.1401 a new self-signed
root CA appeared on every run (deploy-configure-rke#44, fixed).

## Notes

- **UFW:** baseos leaves UFW active with an allow list (22, 443, 6443,
  8472/udp, 30000-33000, …) and no rule for 80/tcp. The Gateway VIP is still
  reachable on 80 and 443: Cilium's eBPF kube-proxy replacement handles the VIP
  traffic before netfilter's INPUT chain sees it.
- **Lab DNS:** a workstation in one lab may not resolve another lab's zones
  (LabDA vs. labul); check names from the node.
- **Fully offline** is a separate step: the role's air-gap vars
  (`k3s_airgapped_*`, `cilium_airgapped_*`) and a registry on the node
  ([runbook](./runbook.md), *Still online*).
- Runs so far: [`clusters/edge/k3s`](../../clusters/edge/k3s/README.md)
  (`edge-tt-test1`: CLI, then Dagger -- both green, idempotent).

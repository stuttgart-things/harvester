# Edge cluster -- k3s + Cilium

Runbook step 3 in full: how an edge node gets its Kubernetes -- every file and
every command. `sthings.rke.k3s_cluster` (role deploy-configure-rke) against a
host whose base OS is done (`sthings.baseos.setup`). Back to the
[runbook](./runbook.md).

**Built for Flux.** This k3s is only the foundation: right after it, Flux is
bootstrapped onto it (runbook step 6) and from then on runs everything on the
cluster -- Cilium's LB pool and Gateways, cert-manager, the apps -- from this
git repo. So the k3s install sets up exactly what Flux builds on (Cilium with
Gateway API and L2 announcements, `local-path`, no traefik/servicelb), nothing
more.

**One folder per cluster, in git.** The same cluster folder,
`clusters/<cluster>/`, holds both: the **k3s part** in `k3s/` (inventory, vars,
collections -- input for Ansible, not for Flux: `.sourceignore` keeps Flux
away from it) and, after step 5, the **Flux part** (`cluster-apps.yaml`,
`cluster-vars.yaml`, the generated files) that Flux syncs. One place to see,
review and rebuild a cluster; the k3s files are versioned like everything else
and a rebuild uses exactly what is committed.

## What you get

| | |
|---|---|
| k3s | `v1.35.9+k3s1`, single node, **sqlite/kine** (no embedded etcd: one node that never grows, less RAM, fewer writes on the eMMC; not changeable in place later) |
| Off by the role's defaults | flannel, kube-proxy, network policy, servicelb, traefik |
| Kept | `local-path` -- the default StorageClass |
| Cilium | 1.20.2 (the first line tested with k8s 1.35), installed by cilium-cli 0.20.1: kube-proxy replacement, Gateway API (+ ALPN, appProtocol), L2 announcements, cluster pool `10.42.0.0/16`, `k8sServiceHost` = the node's default IPv4 |
| Gateway API | CRDs v1.6.1 (standard), applied server-side; GatewayClass `cilium`. Moving to v1.6.x is one-way |
| Kubeconfig | fetched by the role to `fetched_kubeconfig_path` on the **Ansible controller**, server already the node's address |
| CLIs on the node | from the k3s run: `kubectl`, `helm`, `cilium`; from the tools run ([below](#tools-on-the-node)): `k9s`, `flux`, `sops`, `age`, `age-keygen` |

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
- **SSH: offer only the right key.** Ubuntu 26.04's OpenSSH penalises a source
  after failed logins (`PerSourcePenalties`) and then answers with
  `Connection closed` -- which happens when your agent offers other keys
  first, Ansible opening several connections. Pin the key:
  `export ANSIBLE_SSH_ARGS='-o IdentitiesOnly=yes -o ControlMaster=auto -o ControlPersist=60s'`
  (and `ssh -o IdentitiesOnly=yes …`). Seen on 2026-10-06 on `edge-tt-test1`:
  the play failed with `UNREACHABLE … Connection closed`, with the option it
  ran.

## Deployment -- two options

Both run the same playbook with the same three files and end in the same
cluster; pick by what is installed where you work.

| | Option 1: Ansible CLI | Option 2: Dagger |
|---|---|---|
| Runs on | your workstation, a Python venv | a container (`blueprints/vm` `execute-ansible-with-export`) |
| You install | Python 3, Ansible 14.4.0 (ansible-core >= 2.19), the collections | the Dagger CLI and a container runtime (Docker) -- nothing else |
| SSH to the node | your key | user + password, read from a file |
| Kubeconfig | lands on your machine directly | exported out of the container (`--export-paths`) |
| Good for | iterating on the role or vars, debugging (`-vvv`, `--check`, `--start-at-task`) | a reproducible run with a pinned toolchain, the same way a pipeline runs it; no local Ansible to keep up to date |

### Deployment option 1: Ansible CLI

The playbook runs from your own machine. **Advantages:** the fastest loop when
you change the role or the vars, the full Ansible toolbox for debugging, and
key-based SSH; the kubeconfig is fetched straight to your machine.
**Requirements:** Python 3 with `venv`, Ansible 14.4.0 (ansible-core >= 2.19 --
the node runs Python 3.14 on Ubuntu 26.04, which 2.17 does not support), the
collections from `requirements.yaml`, and your SSH key on the node
(`sthings`, NOPASSWD sudo).

Once per workstation:

```bash
python3 -m venv ~/ansible-venv                                  # if not there yet
```

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

### Deployment option 2: Dagger

`blueprints/vm` `execute-ansible-with-export`: the same playbook, vars,
inventory and requirements in an Ansible container. **Advantages:** nothing
but Dagger on your machine -- Ansible, ansible-core and the collections come
pinned in the container, so every run (yours, a colleague's, a pipeline's) uses
the same toolchain; no venv to maintain. **Requirements:** the Dagger CLI
(tested with v0.21.10) and a container runtime for its engine (Docker), the
node's `sthings` password (the module authenticates with **user +
password**). The password comes from a file (mode 600, created by
hand, never in a command, the environment or a log); Dagger masks it in the
output -- and every other secret value too, so the user `sthings` shows up as
`***` (`***.rke.install_requirements`). Docker and the Dagger CLI as
Ansible code: [Workstation setup](../workstation.md).

```bash
# 1. the node's sthings password into a file
install -m 600 /dev/null ~/.$CLUSTER.pass
nano ~/.$CLUSTER.pass

# 2. k3s + Cilium; --export-paths copies the fetched kubeconfig out of the
#    container (by file name), `export --path` writes it to the host
export SSH_USER=sthings
env -u SSH_AUTH_SOCK dagger call -m github.com/stuttgart-things/blueprints/vm@v3.11.0 \
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

## Tools on the node

So the cluster can be worked with **on the box** too -- at the table there is
no workstation: `k9s`, the `flux` CLI, `sops` and `age`, from our collection's
tools playbook **`sthings.container.tools`** (role `download_install_binary`).
The playbook installs every entry of the `bin` dict; passed as extra vars, the
cluster's own `tools.yaml` replaces the collection's full list (kind, argocd,
velero, …) with exactly these. Each entry checks the installed version first
and downloads only on a mismatch, so a rerun changes nothing. `kubectl`,
`helm` and `cilium` are not in it: the k3s run installs them, and listing them
again would make the two plays overwrite each other's versions.
`sthings.container` is already in `requirements.yaml`.

### `clusters/$CLUSTER/k3s/tools.yaml`

```bash
cat > clusters/$CLUSTER/k3s/tools.yaml <<'EOF'
---
# The CLIs on the edge node, so the cluster can be worked with ON the box
# (no workstation at the table): sthings.container.tools with THIS selection.
# The playbook installs every entry of `bin` -- passed as extra vars, this
# dict replaces the collection's full tool list (kind, argocd, velero, ...).
# Each entry: version check first (`<bin> <version_cmd>` must contain
# bin_version), download only on a mismatch -- a rerun changes nothing.
# docs/edge/k3s.md, "Tools on the node". NOT here: kubectl, helm and
# cilium-cli -- the k3s run (sthings.rke) already installs them; listing them
# again would make the two plays overwrite each other's versions.
k9s_version: 0.51.0        # datasource=github-tags depName=derailed/k9s
flux_version: 2.9.6        # datasource=github-tags depName=fluxcd/flux2 -- = the cluster's Flux
sops_version: 3.12.1       # datasource=github-tags depName=getsops/sops
age_version: 1.2.1         # datasource=github-tags depName=FiloSottile/age

bin:
  k9s:
    bin_name: k9s
    bin_version: "{{ k9s_version }}"
    check_bin_version_before_installing: true
    source_url: "https://github.com/derailed/k9s/releases/download/v{{ k9s_version }}/k9s_Linux_amd64.tar.gz"
    bin_to_copy: k9s
    to_remove: ""
    bin_dir: /usr/local/bin
    version_cmd: " version --short"
    target_version: "{{ k9s_version }}"
  flux:
    bin_name: flux
    bin_version: "{{ flux_version }}"
    check_bin_version_before_installing: true
    source_url: "https://github.com/fluxcd/flux2/releases/download/v{{ flux_version }}/flux_{{ flux_version }}_linux_amd64.tar.gz"
    bin_to_copy: flux
    to_remove: ""
    bin_dir: /usr/local/bin
    version_cmd: " version --client"
    target_version: "{{ flux_version }}"
  sops:
    bin_name: sops
    bin_version: "{{ sops_version }}"
    check_bin_version_before_installing: true
    source_url: "https://github.com/getsops/sops/releases/download/v{{ sops_version }}/sops-v{{ sops_version }}.linux.amd64"
    bin_to_copy: "sops-v{{ sops_version }}.linux.amd64"
    to_remove: ""
    bin_dir: /usr/local/bin/sops         # a file path: renames the download to sops
    version_cmd: " --version --disable-version-check"
    target_version: "{{ sops_version }}"
  age:
    bin_name: age
    bin_version: "{{ age_version }}"
    check_bin_version_before_installing: true
    source_url: "https://github.com/FiloSottile/age/releases/download/v{{ age_version }}/age-v{{ age_version }}-linux-amd64.tar.gz"
    bin_to_copy: age/age
    to_remove: age
    bin_dir: /usr/local/bin
    version_cmd: " --version"
    target_version: "{{ age_version }}"
  age-keygen:
    bin_name: age-keygen
    bin_version: "{{ age_version }}"
    check_bin_version_before_installing: true
    source_url: "https://github.com/FiloSottile/age/releases/download/v{{ age_version }}/age-v{{ age_version }}-linux-amd64.tar.gz"
    bin_to_copy: age/age-keygen
    to_remove: age
    bin_dir: /usr/local/bin
    version_cmd: " --version"
    target_version: "{{ age_version }}"
EOF
```

### Run

```bash
# Deployment option 1: Ansible CLI
ANSIBLE_BECOME_ASK_PASS=False ~/ansible-venv/bin/ansible-playbook \
  -i clusters/$CLUSTER/k3s/inventory.ini --private-key $EDGE_KEY \
  sthings.container.tools -e @clusters/$CLUSTER/k3s/tools.yaml

# Deployment option 2: Dagger -- one command, no inventory file
env -u SSH_AUTH_SOCK dagger call -m github.com/stuttgart-things/blueprints/vm@v3.11.0 \
  execute-ansible \
  --hosts $NODE_IP \
  --playbooks sthings.container.tools \
  --parameters-file ./clusters/$CLUSTER/k3s/tools.yaml \
  --ssh-user env:SSH_USER \
  --ssh-password file:$HOME/.$CLUSTER.pass \
  --progress plain
```

`--parameters-file` needs blueprints/vm **v3.11.0** or newer. Older versions
turn every dict into a string, and the play fails with `the 'dict' lookup
plugin expects a dictionary` (blueprints#217). On an older version, use
`--src ./clusters/$CLUSTER/k3s --parameters profile=/src/tools` instead: the
playbook then loads `/src/tools.yaml` through its own `vars_files`. Without
`--requirements`, the module takes the collections from the ansible repo's
`main`; that is fine for this play.

### A kubeconfig on the node

k3s writes `/etc/rancher/k3s/k3s.yaml` readable by root only. For `k9s`,
`flux` and `kubectl` as `sthings` on the node:

```bash
ssh -o IdentitiesOnly=yes sthings@$NODE_IP \
  'mkdir -p ~/.kube && sudo install -o "$(id -u)" -g "$(id -g)" -m 600 /etc/rancher/k3s/k3s.yaml ~/.kube/config'
# then on the node: k9s · flux get ks -A · kubectl get pods -A
```

It points at `127.0.0.1:6443` -- right on the node itself.

### Check the tools

```bash
ssh -o IdentitiesOnly=yes sthings@$NODE_IP \
  'k9s version --short | head -1; flux version --client; sops --version --disable-version-check | head -1; age --version'
```

`edge-tt-test1` (2026-10-06, option 1): `ok=71 changed=19`, then a second run
`ok=46 changed=0`; k9s v0.51.0, flux v2.9.6, sops 3.12.1, age v1.2.1;
`flux get ks -A` as `sthings` on the node.
`edge-tt-test2` (option 2): on 2026-10-06 with v3.10.0 and the `profile`
workaround, `ok=71 changed=19 failed=0` and the same versions. On 2026-10-07 with v3.11.0
and `--parameters-file` (the command above), `ok=46 changed=0`.

## Keep the kubeconfig in the repo

Encrypted, so the team (and later steps such as Terraform) get cluster access
from git -- the k3s kubeconfig holds a cluster-admin certificate, so never in
plaintext. SOPS, the age key and both ways (CLI or Dagger):
[SOPS + age](../sops.md).

```bash
AGE_PUB=$(age-keygen -y <<<"$SOPS_AGE_KEY")
sops --encrypt --age "$AGE_PUB" --input-type yaml --output-type yaml \
  ~/.kube/$CLUSTER > secrets/edge/kubeconfig-$CLUSTER.enc.yaml
sops -d secrets/edge/kubeconfig-$CLUSTER.enc.yaml | KUBECONFIG=/dev/stdin kubectl get nodes   # check
# restore on another machine:
#   (umask 077; sops -d secrets/edge/kubeconfig-$CLUSTER.enc.yaml > ~/.kube/$CLUSTER)
```

Name it after the node (`kubeconfig-edge-tt-test1.enc.yaml`) when the
kubeconfig file is named that way.

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
- Runs so far: [`clusters/edge/k3s`](https://github.com/stuttgart-things/harvester/blob/main/clusters/edge/k3s/README.md)
  (`edge-tt-test1`: CLI, then Dagger -- both green, idempotent).

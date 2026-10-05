# clusters/edge-test2/k3s

k3s + Cilium for `edge-tt-test2` (labul Proxmox, `10.31.102.144`) -- runbook
step 3. The same playbook, vars and collections as
[`../../edge/k3s`](../../edge/k3s/README.md) (which explains what the role
configures); only the inventory, `cluster_name` (`edge-test2`) and the fetched
kubeconfig path differ. **Flux never reads this folder.**

| File | |
|---|---|
| [`inventory.ini`](./inventory.ini) | the node, `10.31.102.144` |
| [`k3s-vars.yaml`](./k3s-vars.yaml) | k3s 1.35.9+k3s1 on sqlite, Cilium 1.20.2 (cilium-cli 0.20.1), Gateway API v1.6.1; `fetched_kubeconfig_path: /tmp/kubeconfig-edge-test2.yaml` |
| [`requirements.yaml`](./requirements.yaml) | collections, sthings.rke 26.1003.1401 |

Two ways, same result -- pick one:

| | A) Ansible CLI | B) Dagger |
|---|---|---|
| Runs on | your workstation's venv | a container (`blueprints/vm`) |
| SSH | your key | user + password (from a file) |
| Kubeconfig | lands on your machine directly | exported out of the container (`--export-paths`) |

The role **fetches the kubeconfig with the server already rewritten to the
node's address** to `fetched_kubeconfig_path` on the **Ansible controller**.
With the CLI that is your machine; with Dagger it is the container -- hence
the export.

## A) Ansible CLI

Once per workstation (ansible-core >= 2.19: the node runs Python 3.14):

```bash
~/ansible-venv/bin/pip install --upgrade "ansible==14.4.0"      # -> ansible-core 2.21.4
~/ansible-venv/bin/ansible-galaxy collection install -r clusters/edge-test2/k3s/requirements.yaml --upgrade
~/ansible-venv/bin/ansible-galaxy collection list | grep sthings  # rke 26.1003.1401
```

`--upgrade` matters: an older `sthings.rke` in `~/.ansible/collections` would
silently ignore `cilium_chart_version` and `k3s_cluster_init`.

Access: key-based SSH as `sthings`, NOPASSWD sudo. The repo's `ansible.cfg`
sets `become_ask_pass = True`; the run overrides it.

```bash
cd ~/projects/harvester
export EDGE_KEY=~/.ssh/id_ed25519           # whichever key is on the node

# 1. connection + facts
~/ansible-venv/bin/ansible -i clusters/edge-test2/k3s/inventory.ini all \
  --private-key $EDGE_KEY -m ansible.builtin.setup -a 'filter=ansible_distribution*'

# 2. k3s + Cilium
ANSIBLE_BECOME_ASK_PASS=False ~/ansible-venv/bin/ansible-playbook \
  -i clusters/edge-test2/k3s/inventory.ini --private-key $EDGE_KEY \
  sthings.rke.k3s_cluster \
  -e @clusters/edge-test2/k3s/k3s-vars.yaml

# 3. the kubeconfig -- fetched by the role, server = the node's address
install -m 600 /tmp/kubeconfig-edge-test2.yaml ~/.kube/edge-tt-test2 && rm /tmp/kubeconfig-edge-test2.yaml
grep server: ~/.kube/edge-tt-test2                # https://10.31.102.144:6443
```

If base OS updated the kernel ("System restart required"), reboot the node
before step 2: `ssh sthings@10.31.102.144 sudo reboot`.

## B) Dagger

From the repo root. The password comes from a file (mode 600, created by hand,
never in a command, the environment or a log); Dagger masks it in the output
-- and the user name too (`***.rke…`).

```bash
cd ~/projects/harvester

# 1. the node's sthings password into a file
install -m 600 /dev/null ~/.edge-tt-test2.pass
nano ~/.edge-tt-test2.pass

# 2. k3s + Cilium -- execute-ansible-WITH-EXPORT: the role fetches the
#    kubeconfig (server rewritten to the node's address) to
#    fetched_kubeconfig_path on the Ansible controller, which is the Dagger
#    container; --export-paths copies it out (by its file name)
export SSH_USER=sthings
env -u SSH_AUTH_SOCK dagger call -m github.com/stuttgart-things/blueprints/vm@v3.10.0 \
  execute-ansible-with-export \
  --src ./clusters/edge-test2/k3s \
  --playbooks sthings.rke.k3s_cluster \
  --inventory ./clusters/edge-test2/k3s/inventory.ini \
  --parameters-file ./clusters/edge-test2/k3s/k3s-vars.yaml \
  --requirements ./clusters/edge-test2/k3s/requirements.yaml \
  --ssh-user env:SSH_USER \
  --ssh-password file:$HOME/.edge-tt-test2.pass \
  --export-paths /tmp/kubeconfig-edge-test2.yaml \
  export --path /tmp/edge-test2-k3s 2>&1 | tee /tmp/k3s-edge-test2.log

shred -u ~/.edge-tt-test2.pass
grep -A2 'PLAY RECAP' /tmp/k3s-edge-test2.log     # failed=0

# 3. the kubeconfig
install -m 600 /tmp/edge-test2-k3s/kubeconfig-edge-test2.yaml ~/.kube/edge-tt-test2 && rm -rf /tmp/edge-test2-k3s
grep server: ~/.kube/edge-tt-test2                # https://10.31.102.144:6443
```

`env -u SSH_AUTH_SOCK`: a stale agent socket makes Dagger fail with
`failed to list SSH agent identities`. More files out of the container: list
them comma-separated in `--export-paths`.

**Plain `execute-ansible` (no `-with-export`) loses the kubeconfig**: the fetch task reports
*changed*, but into the container's `/tmp`, which is gone afterwards (the first
run on 2026-10-05 used it). Then take it from the node instead -- k3s writes
`127.0.0.1`, so replace the address:

```bash
ssh sthings@10.31.102.144 sudo cat /etc/rancher/k3s/k3s.yaml \
  | sed 's/127.0.0.1/10.31.102.144/' > ~/.kube/edge-tt-test2 && chmod 600 ~/.kube/edge-tt-test2
```

## Verify

```bash
export KUBECONFIG=~/.kube/edge-tt-test2
kubectl get nodes -o wide                       # Ready, v1.35.9+k3s1
kubectl -n kube-system get pods                 # cilium, cilium-envoy, cilium-operator, coredns, local-path-provisioner, metrics-server
kubectl get gatewayclass cilium                 # Accepted
kubectl get crd | grep -c gateway.networking.k8s.io   # 10 (Gateway API v1.6.1, standard)
kubectl get storageclass                        # local-path (default)
```

## Last run

2026-10-05, B) Dagger with plain `execute-ansible`: node Ready 19:27 UTC
(k3s v1.35.9+k3s1, Cilium up); kubeconfig taken from the node.

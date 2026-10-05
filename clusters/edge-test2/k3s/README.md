# clusters/edge-test2/k3s

k3s + Cilium for `edge-tt-test2` (labul Proxmox, `10.31.102.144`) -- runbook
step 3. The same playbook, vars and collections as
[`../../edge/k3s`](../../edge/k3s/README.md) (which explains every variable and
the CLI run); only the inventory, `cluster_name` (`edge-test2`) and the
fetched kubeconfig path differ.

| File | |
|---|---|
| [`inventory.ini`](./inventory.ini) | the node, `10.31.102.144` |
| [`k3s-vars.yaml`](./k3s-vars.yaml) | k3s 1.35.9+k3s1 on sqlite, Cilium 1.20.2 (cilium-cli 0.20.1), Gateway API v1.6.1 |
| [`requirements.yaml`](./requirements.yaml) | collections, sthings.rke 26.1003.1401 |

## Run (Dagger)

From the repo root. The password comes from a file (mode 600, created by hand,
never in a command, the environment or a log); Dagger masks it in the output
-- and the user name too (`***.rke…`).

```bash
cd ~/projects/harvester

# 1. the node's sthings password into a file
install -m 600 /dev/null ~/.edge-tt-test2.pass
nano ~/.edge-tt-test2.pass

# 2. k3s + Cilium
SSH_USER=sthings env -u SSH_AUTH_SOCK dagger call -m github.com/stuttgart-things/blueprints/vm@v3.10.0 \
  execute-ansible \
  --src ./clusters/edge-test2/k3s \
  --playbooks sthings.rke.k3s_cluster \
  --inventory ./clusters/edge-test2/k3s/inventory.ini \
  --parameters-file ./clusters/edge-test2/k3s/k3s-vars.yaml \
  --requirements ./clusters/edge-test2/k3s/requirements.yaml \
  --ssh-user env:SSH_USER \
  --ssh-password file:$HOME/.edge-tt-test2.pass \
  --progress plain 2>&1 | tee /tmp/k3s-edge-test2.log

shred -u ~/.edge-tt-test2.pass
grep -A2 'PLAY RECAP' /tmp/k3s-edge-test2.log     # failed=0

# 3. the kubeconfig (k3s writes 127.0.0.1 -> the node's address)
ssh sthings@10.31.102.144 sudo cat /etc/rancher/k3s/k3s.yaml \
  | sed 's/127.0.0.1/10.31.102.144/' > ~/.kube/edge-tt-test2 && chmod 600 ~/.kube/edge-tt-test2
```

`env -u SSH_AUTH_SOCK`: a stale agent socket makes Dagger fail with
`failed to list SSH agent identities`.

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

_Not run yet._

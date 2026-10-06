# clusters/edge-test2/k3s -- k3s + Cilium on `edge-tt-test2`

The k3s files of `edge-tt-test2` (labul Proxmox) -- runbook step 3. **How it
works, every file and every command: [`docs/edge/k3s.md`](../../../docs/edge/k3s.md)**
-- run it with:

```bash
CLUSTER=edge-test2
NODE_IP=10.31.102.144
export KUBECONFIG=~/.kube/edge-tt-test2     # this cluster's kubeconfig name (instead of ~/.kube/$CLUSTER)
```

**Flux never reads this folder.**

| File | |
|---|---|
| [`inventory.ini`](./inventory.ini) | the node, `10.31.102.144` |
| [`k3s-vars.yaml`](./k3s-vars.yaml) | as in `docs/edge/k3s.md`: `cluster_name: edge-test2`, `fetched_kubeconfig_path: /tmp/kubeconfig-edge-test2.yaml` |
| [`requirements.yaml`](./requirements.yaml) | collections, sthings.rke 26.1003.1401 |
| [`tools.yaml`](./tools.yaml) | the CLIs on the node (`sthings.container.tools`): k9s, flux, sops, age -- [Tools on the node](../../../docs/edge/k3s.md#tools-on-the-node) |

| The node | |
|---|---|
| VM | `edge-tt-test2` / `10.31.102.144` (DHCP), labul Proxmox VM-ID 131, Ubuntu 26.04.1 |
| Built by | Backstage `create-vm` (use case baseos), stuttgart-things#3474: Crossplane `NativeProxmoxVM` on machinery + its AnsibleRun (`sthings.baseos.setup`) |
| Access | key (CLI), user + password (Dagger) |

## Last run: 2026-10-05, Dagger

B) Dagger with **plain** `execute-ansible` (before `-with-export` was in the
docs), blueprints/vm v3.10.0:

| | Result |
|---|---|
| Node | `edge-tt-test2.labul.sva.de` Ready 19:27 UTC, **v1.35.9+k3s1**, Ubuntu 26.04.1, no reboot required |
| kube-system | cilium, cilium-envoy, cilium-operator, coredns, local-path-provisioner, metrics-server -- all Running |
| Cilium | `quay.io/cilium/cilium:v1.20.2`; kube-proxy-replacement, Gateway API, L2 announcements, `10.42.0.0/16` |
| Gateway API | 10 CRDs, bundle v1.6.1, GatewayClass `cilium` Accepted |
| Datastore / storage | sqlite (`state.db`), `local-path` (default) |
| Kubeconfig | lost with the container (plain `execute-ansible`); taken from the node with the `sed` fallback, `server: https://10.31.102.144:6443` |

The same result as `edge-tt-test1` ([`../../edge/k3s`](../../edge/k3s/README.md)).

## Tools on the node: 2026-10-06, Dagger

[Tools on the node](../../../docs/edge/k3s.md#tools-on-the-node), option 2 --
the first Dagger run of `sthings.container.tools` (test1 used the CLI).
One command, no inventory file:

```bash
env -u SSH_AUTH_SOCK dagger call -m github.com/stuttgart-things/blueprints/vm@v3.10.0 \
  execute-ansible \
  --hosts 10.31.102.144 \
  --src ./clusters/edge-test2/k3s \
  --playbooks sthings.container.tools \
  --parameters profile=/src/tools \
  --ssh-user env:SSH_USER \
  --ssh-password file:$HOME/.edge-test2.pass \
  --progress plain
```

| | Result |
|---|---|
| First try | `--parameters-file ./clusters/edge-test2/k3s/tools.yaml` failed: the module turns the `bin` dict into a string (`the 'dict' lookup plugin expects a dictionary`) -- blueprints#217 |
| Workaround | `--src` mounts the folder at `/src`, `profile=/src/tools` makes the playbook load `/src/tools.yaml` itself (`vars_files: "{{ profile }}.yaml"`) |
| Run | `ok=71 changed=19 failed=0` -- the same counts as test1's first run |
| On the node | k9s v0.51.0, flux v2.9.6, sops 3.12.1, age v1.2.1 |

The kubeconfig is in git, encrypted:
[`secrets/edge/kubeconfig-edge-tt-test2.enc.yaml`](../../../secrets/edge/kubeconfig-edge-tt-test2.enc.yaml)
(Dagger `sops` `encrypt`, checked with `sops -d … | KUBECONFIG=/dev/stdin kubectl get nodes`).

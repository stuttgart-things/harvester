# clusters/edge/k3s -- k3s + Cilium on `edge-tt-test1`

The k3s files of `edge-tt-test1` (LabDA). **How it works, every file and every
command: [`docs/edge/k3s.md`](../../../docs/edge/k3s.md)** -- run it with:

```bash
CLUSTER=edge
NODE_IP=10.100.136.89
export KUBECONFIG=~/.kube/edge-tt-test1     # this cluster's kubeconfig name (instead of ~/.kube/$CLUSTER)
```

**Flux never reads this folder** ([`../.sourceignore`](../.sourceignore)).

| File | |
|---|---|
| [`inventory.ini`](./inventory.ini) | the node, `10.100.136.89` |
| [`k3s-vars.yaml`](./k3s-vars.yaml) | k3s 1.35.9 on sqlite, Cilium 1.20.2 (cilium-cli 0.20.1), Gateway API v1.6.1; `cluster_name: edge`, `fetched_kubeconfig_path: /tmp/kubeconfig-edge.yaml` |
| [`requirements.yaml`](./requirements.yaml) | collections, sthings.rke 26.1003.1401 |
| [`tools.yaml`](./tools.yaml) | the CLIs on the node (`sthings.container.tools`): k9s, flux, sops, age |

| The node | |
|---|---|
| VM | `edge-tt-test1` / `10.100.136.89`, LabDA vSphere, Ubuntu 26.04 (`sthings-u26`), 8 vCPU / 15Gi / 128Gi |
| Built by | Backstage `request-vm` (stuttgart-things#3415) → Dapr worker on `cicd-machinery-test5` → `create-terraform-vm` build PR (#3418): Terraform + `sthings.baseos.setup` |
| Access | key `~/.ssh/id_ed25519_edge` (CLI), user + password (Dagger) |

## Tools run: 2026-10-06, CLI

`sthings.container.tools -e @tools.yaml` (option 1, sthings.container
26.1002.1398): the first attempt failed `UNREACHABLE ... Connection closed`
(OpenSSH `PerSourcePenalties` after the agent offered other keys) -- with
`ANSIBLE_SSH_ARGS='-o IdentitiesOnly=yes ...'` `ok=71 changed=19 failed=0`, a
second run `ok=46 changed=0`. On the node: k9s v0.51.0, flux v2.9.6, sops
3.12.1, age/age-keygen v1.2.1 (next to kubectl v1.36.5, helm v4.2.4, cilium
v0.20.1 from the k3s run); `~/.kube/config` for `sthings`, `flux get ks -A` works.

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

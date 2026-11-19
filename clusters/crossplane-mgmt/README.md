# clusters/crossplane-mgmt

The **crossplane-mgmt** cluster: the control plane where Crossplane runs. It is
registered in the `platform` cluster's Argo CD (see
`../platform/clusters/crossplane-mgmt.yaml`), and two Applications declared in
`../platform/clusters/platform-crossplane-showcase-apps.yaml` sync this
directory onto it.

| Path | Synced by | Prune | What |
|---|---|---|---|
| [`platform/`](./platform/) | Application `showcase-crossplane-platform` | **off** | Crossplane Configurations, their EnvironmentConfigs, RBAC, namespaces, the PKI source Secrets. Prune is off on purpose: pruning a Configuration triggers foreground deletion and cascade-deletes every XR built from it |
| [`xrs/`](./xrs/) | Application `showcase-crossplane-xrs` | on | The resource claims themselves — `XVirtualMachine`, `AnsibleRun`, namespaces. `catalog-info.yaml` / `kustomization.yaml` are excluded by the Application (Backstage/kustomize artifacts, not CRDs) |
| [`../shared/crossplane-observability/`](../shared/crossplane-observability/) | Application `crossplane-mgmt-crossplane-observability` | on | Scraping of Crossplane core/providers/functions, XR/MR Ready+Synced metrics, alert `CrossplaneXRNotReady`, Grafana folder "Crossplane". Shared with machinery-hv |
| [`openbao/`](./openbao/) | nobody — `terraform apply` by hand | — | Vault/OpenBao auth + PKI config for this cluster |
| `env-config-harvester.yaml` | nobody — `kubectl apply` by hand | — | See the warning below |

Both trees lived in `stuttgart-things/crossplane-configurations` under
`tests/envs/harvester/` until 2026-09-12. They are the target environment's own
state, not fixtures of that repo. What CI they had there was uneven: `xrs/` was
gated by that repo's `validate-claims.yaml` (Kyverno policies over the claims),
while `platform/` — the Configurations, EnvironmentConfigs and RBAC that Argo
syncs with `selfHeal` — sat in `verify.yaml`'s `paths-ignore` and was checked by
nothing at all. Here `clusters/**` goes through `pr-lint.yml` (pre-commit), and
the Kyverno gate came along as
[`.github/workflows/validate-claims.yml`](../../.github/workflows/validate-claims.yml),
which still reads its policies out of the other repo so there is one source for
them.

The cluster itself (k8s, CNI) is not built from this repo. It runs **Cilium
1.19.5** (Helm revision 3, upgraded from 1.19.3 on 2026-11-17, #679); nothing
here pins that. A rebuild without an explicit `cilium_chart_version` gets
whatever the cilium-cli default is at that time -- set
`cilium_chart_version="1.19.5"` (or a deliberately chosen version) on that run.

The release has `image.pullPolicy: Never` (agent, operator, envoy): the node
never pulls Cilium images itself. Before any Cilium upgrade, pull the new images
on the node first, or the agent ends in `ErrImageNeverPull` and the node loses
its CNI. Take the digests from the target chart's `values.yaml`:

```bash
ssh sthings@192.168.10.108 'sudo k3s crictl pull quay.io/cilium/cilium:v1.19.5@sha256:20fbbc14ac20b55a292c0dcda5571bf31cde30a7dbc68c29db3e709390ab0732'
# same for operator-generic and cilium-envoy
helm upgrade cilium cilium --repo https://helm.cilium.io --version 1.19.5 \
  -n kube-system --reset-then-reuse-values
```

`--reset-then-reuse-values`, not `--reuse-values`: the latter keeps the old
chart's defaults, image tags included, so the "upgrade" renders the old images.

> [!WARNING]
> **`env-config-harvester.yaml` collides with `platform/virtual-machine/env-config-harvestervm.yaml`.**
> Different names (`harvester-vm-remote-defaults` vs `harvestervm-defaults`),
> byte-identical `data`, and the **same selector label**
> `harvester-vm.resources.stuttgart-things.com/environment: default`. The
> `harvester-vm` Composition selects with `function-environment-configs` in its
> default `mode: Single`, which wants exactly one match — with both applied, the
> selection is not what anyone intended. The GitOps'd one under `platform/` is
> the owner; the file in this directory is the hand-applied predecessor, kept
> only because the commands below are a bootstrap runbook. Check the cluster
> before trusting either:
>
> ```bash
> kubectl --kubeconfig ~/.kube/crossplane-mgmt get environmentconfigs \
>   -l harvester-vm.resources.stuttgart-things.com/environment=default
> ```
>
> If both are there, delete `harvester-vm-remote-defaults` — nothing manages it.

## Kernel pinned to 7.0.0-38-generic (#697)

The node boots **7.0.0-38-generic** on purpose. On 7.0.0-42, the containerd AppArmor
profile `cri-containerd.apparmor.d` denies signals between Postgres processes,
and CNPG databases hang (logins stuck in `authentication`, "too many clients").
The node never booted -42 or -43 (-43 was already installed). The pin keeps it from doing so.

- `/etc/default/grub`: `GRUB_DEFAULT` points at the -38 entry (original: `/etc/default/grub.bak-697`).
- `apt-mark hold linux-virtual linux-image-virtual linux-headers-virtual linux-headers-generic`: no new kernels, and no kernel security updates.
- Remove the pin only after #697 is fixed: restore the backup, run `update-grub` and `apt-mark unhold` on the same packages, then reboot. Kured (#674) waits for this.

## Manual one-offs

### TLSRoute CRD (2026-11-17, #671)

Cilium 1.19.3 (now 1.19.5), Gateway API CRDs v1.4.1. The experimental
TLSRoute CRD v1.4.1 was applied by hand; without it the cilium-operator logs `no kind is registered
for the type v1alpha2.TLSRouteList` and never re-resolves HTTPRoutes, so a route
created before its Service stays at `BackendNotFound` (cilium/cilium#47819).
Raise it with every Gateway API upgrade:

```bash
export KUBECONFIG=~/.kube/crossplane-mgmt
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.4.1/config/crd/experimental/gateway.networking.k8s.io_tlsroutes.yaml
kubectl -n kube-system rollout restart deploy/cilium-operator
```

Before: 42 errors/h, after: 0; 2/2 HTTPRoutes `ResolvedRefs=True`, both 200.

### RancherCluster path -- retired 2026-11-19 (harvester#601)

crossplane-mgmt no longer orders Rancher clusters. Its only RancherCluster,
`tabletennis`, was retired (#782); new clusters are ordered as `ClusterStack`
on machinery-hv (scoped SA `crossplane-machinery`, `no-creator-rbac`). Removed
with it:

- `platform/rancher-cluster/` -- Configuration `rancher-cluster` v0.7.4,
  EnvironmentConfig `rancher-cluster-defaults`, the downstream CA source Secret
  `cert-manager/openbao-pki-ca`. Prune is off for `platform/`, so the live
  objects were deleted by hand after the merge.
- The hand-applied ClusterProviderConfig `rancher-mgmt` and its Secret
  `crossplane-system/rancher-mgmt-kubeconfig-scoped` (deleted by hand; never in
  git). The earlier admin Secret `rancher-mgmt-kubeconfig` (platform's k3s
  admin kubeconfig) was already deleted on 2026-11-19 (#350).
- `rancher-mgmt-credential.sh` and, on platform,
  `../platform/crossplane-mgmt-access.yaml` (#701: namespace, SA and bindings
  `crossplane-mgmt-access`; Flux prunes them).

`harvester` and `in-cluster` remain the only ClusterProviderConfigs here.
machinery-hv keeps its own `rancher-mgmt` and the RancherCluster XRs its
ClusterStacks compose -- that path is unaffected.

### provider-kubernetes runtime config (2026-09-30)

The Provider is installed as a Configuration dependency and is not in git, so
its `runtimeConfigRef` is set by hand. The DeploymentRuntimeConfig it points at
is GitOps'd: [`platform/providers/drc-provider-kubernetes.yaml`](./platform/providers/drc-provider-kubernetes.yaml)
(`--poll=1m`, `--enable-watches`, see the comment there). After Argo CD has synced it:

```bash
export KUBECONFIG=~/.kube/crossplane-mgmt
kubectl get deploymentruntimeconfigs.pkg.crossplane.io provider-kubernetes
kubectl patch providers.pkg.crossplane.io crossplane-contrib-provider-kubernetes --type merge \
  -p '{"spec":{"runtimeConfigRef":{"apiVersion":"pkg.crossplane.io/v1beta1","kind":"DeploymentRuntimeConfig","name":"provider-kubernetes"}}}'
kubectl -n crossplane-system get $(kubectl -n crossplane-system get deploy -o name | grep provider-kubernetes) \
  -o jsonpath='{.spec.template.spec.containers[0].args}'
```

Rollback: patch `name` back to `default`.




kubectl create secret generic crossplane-mgmt   --namespace argocd   --from-file=kubeconfig=/home/sthings/.kube/crossplane-mgmt
secret/crossplane-mgmt created

dagger call -m github.com/stuttgart-things/dagger/sops encrypt   --age-key env:AGE_PUB   --plaintext-file ~/.kube/crossplane-mgmt   --file-extension yaml   export --path=/home/sthings/harvester/secrets/crossplane-mgmt.sthings.lab


# NOTE: historical. The Vault this points at ran on infra, which is gone, and
# clusters/infra/vault-infra-lab.enc.yaml went with it (git history has it).
# Issuers now come from the OpenBao on platform -- see clusters/OPENBAO-CLUSTERBOOK.md.
# CREATE — override Secret names / namespace / TTL
dagger call -m github.com/stuttgart-things/blueprints/argocd create-vault-issuer \
  --cluster-name homerun2-dev \
  --kubeconfig-source-file /home/sthings/harvester/secrets/crossplane-mgmt.sthings.lab.yaml \
  --vault-env-file /home/sthings/harvester/clusters/infra/vault-infra-lab.enc.yaml \
  --sops-key env:SOPS_AGE_KEY \
  --target-namespace cert-manager \
  --token-secret-name cert-manager-vault-token \
  --ca-secret-name vault-pki-ca \
  --token-ttl 8760h \
  --progress plain

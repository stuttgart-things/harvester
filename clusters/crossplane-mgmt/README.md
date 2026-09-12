# clusters/crossplane-mgmt

The **crossplane-mgmt** cluster: the control plane where Crossplane runs. It is
registered in the `platform` cluster's Argo CD (see
`../platform/clusters/crossplane-mgmt.yaml`), and two Applications declared in
`../platform/clusters/platform-crossplane-showcase-apps.yaml` sync this
directory onto it.

| Path | Synced by | Prune | What |
|---|---|---|---|
| [`platform/`](./platform/) | Application `showcase-crossplane-platform` | **off** | Crossplane Configurations, their EnvironmentConfigs, RBAC, namespaces, the PKI source Secrets. Prune is off on purpose: pruning a Configuration triggers foreground deletion and cascade-deletes every XR built from it |
| [`xrs/`](./xrs/) | Application `showcase-crossplane-xrs` | on | The resource claims themselves — `RancherCluster`, `XVirtualMachine`, `AnsibleRun`, namespaces. `catalog-info.yaml` / `kustomization.yaml` are excluded by the Application (Backstage/kustomize artifacts, not CRDs) |
| [`openbao/`](./openbao/) | nobody — `terraform apply` by hand | — | Vault/OpenBao auth + PKI config for this cluster |
| `env-config-harvester.yaml` | nobody — `kubectl apply` by hand | — | See the warning below |

Both trees lived in `stuttgart-things/crossplane-configurations` under
`tests/envs/harvester/` until 2026-09-12. They are the target environment's own
state, not fixtures of that repo — and under `tests/` they sat inside its
`verify.yaml` `paths-ignore`, so nothing ever validated them. Here they are
covered by `pr-lint.yml` (pre-commit over `clusters/**`).

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

## Manual one-offs




kubectl create secret generic crossplane-mgmt   --namespace argocd   --from-file=kubeconfig=/home/sthings/.kube/crossplane-mgmt
secret/crossplane-mgmt created

dagger call -m github.com/stuttgart-things/dagger/sops encrypt   --age-key env:AGE_PUB   --plaintext-file ~/.kube/crossplane-mgmt   --file-extension yaml   export --path=/home/sthings/harvester/secrets/crossplane-mgmt.sthings.lab


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

# `machinery-hv` — fleet state

What the cluster **is**, as opposed to what it runs: the provider configs,
EnvironmentConfigs and credentials that make `machinery-hv` the cluster this lab
builds clusters from. Applied by the `machinery-hv-fleet-state` Kustomization in
[`../machinery-hv/fleet-state.yaml`](../machinery-hv/fleet-state.yaml) (`prune: true`,
`dependsOn: cicd-platform`).

Modelled on the LabDA machinery cluster's
[`machinery-fleet-state`](https://github.com/stuttgart-things/stuttgart-things/tree/main/clusters/labda/vsphere/machinery-fleet-state),
with two deliberate differences:

- **No ESO and no sops-git.** Secrets are SOPS-encrypted in `secrets/` and
  decrypted by Flux, like everything else in this repo. LabDA reshapes one
  AppRole blob into four shapes with ExternalSecrets; here each shape is its own
  encrypted file. Simpler to bootstrap, more work to rotate.
- **The Harvester placement and the ansible-run defaults are written out**
  (`environmentconfigs.yaml`) instead of coming from flux's
  `crossplane-capabilities` / `harvester-demo`. That set can be configured for
  this lab since flux v1.80.3 (stuttgart-things/flux#514), but the component
  depends on `sops-git`, which this cluster does not run -- see [`../machinery-hv/cicd-platform.yaml`](../machinery-hv/cicd-platform.yaml).

## What is here

| File | Objects |
|---|---|
| `environmentconfigs.yaml` | `harvestervm-sthings-lab`, `ansible-run-defaults`, `rancher-cluster-join-sthings-lab` |
| `providerconfigs.yaml` | provider-kubernetes `harvester`, `rancher-mgmt` |
| `openbao-pki-source-ca.yaml` | `default/openbao-pki-source-ca`, the OpenBao root the Platform copies onto built clusters |
| `cluster-vault-sthings-lab.yaml` | the OpenBao policy mapping for `environmentConfig: sthings-lab` |
| `vault-provider-configs.yaml` | provider-vault `vault`, `vault-cluster-secrets`, `vault-kubeconfig-writer` |
| `appsecretprofiles.yaml` | `homerun2`, `schmetterpause`, `zaehlwerk`, `tabletennis` |
| `secrets/*.enc.yaml` | the credentials below, SOPS-encrypted, decrypted by Flux |

All listed and applied since 2026-09-24. `secrets/` is **generated**: rendered
and encrypted by
[`../platform/openbao/machinery-fleet/render-fleet-secrets.sh`](../platform/openbao/machinery-fleet/README.md),
never edited by hand.

| Secret | Keys | From |
|---|---|---|
| `tekton-ci/ansible-credentials` | `ANSIBLE_USER`, `ANSIBLE_PASSWORD` | the cloud-init login in `vms/machinery-hv.params.enc.yaml` |
| `crossplane-system/harvester-kubeconfig` | `kubeconfig` | `~/.kube/harvester` |
| `crossplane-system/rancher-mgmt-kubeconfig` | `kubeconfig` | `~/.kube/platform.sthings.lab` -- the admin kubeconfig; a scoped Rancher token would be better |
| `crossplane-system/vault-provider-creds` | `credentials` | AppRole `crossplane` (2nd secret_id) |
| `crossplane-system/vault-creds-cluster-secrets` | `credentials` | AppRole `machinery-hv-cluster-secrets-writer` |
| `crossplane-system/vault-creds-kubeconfig-writer` | `credentials` | AppRole `machinery-hv-kubeconfig-writer` |
| `default/vault-approle`, `vault-cluster-secrets-writer`, `vault-kubeconfig-writer` | `terraform.tfvars` | the same three, for the OpenTofu Workspaces |
| `tekton-ci/vault` | `VAULT_ADDR`, `VAULT_ROLE_ID`, `VAULT_SECRET_ID` | kubeconfig-writer, for the join play's upload. Named `vault` because `ClusterStack.spec.kubeconfig.vaultSecretName` defaults to it and the read side (`vault-kubeconfigs`) is derived from that name |

## Still open

- **`homerun2/_git-pat`** is not seeded (see the OpenBao README). The homerun2
  profile's `githubToken` stays empty until it is.
- **provider-kubeconfig and provider-minio**, below.

## provider-kubeconfig: watch this first

**Confirmed on the first build (2026-09-24), and it is two providers, not one:**
`stuttgart-things-provider-kubeconfig-xpkg` and `vshn-provider-minio` both
report `DeploymentRuntimeConfig "…" not found` and stay `Healthy=False`. It did
**not** block `cicd-platform` -- its health check reads Configurations only --
so this Kustomization and the XR one came up Ready regardless. Both DRCs have to
come from here.

The flux machinery profile (catalog 0.9.0+) points
`stuttgart-things-provider-kubeconfig-xpkg` at a DeploymentRuntimeConfig named
`provider-kubeconfig`, which **the profile does not ship**. On LabDA it comes
from the `provider-kubeconfig-vault` chart in the fleet state, together with
the Vault CA mount and the `vault-kubeconfigs*` ClusterProviderConfigs.

Nothing here installs that chart yet. Expect the provider to stay unhealthy
until something creates that DRC -- and check on the first cold build whether
that blocks `cicd-platform` (and with it this Kustomization, which depends on
it). If it does, the DRC has to come from a Kustomization that does not wait
on `cicd-platform`.

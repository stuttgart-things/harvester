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
  `crossplane-capabilities` / `harvester-demo`, which cannot be configured for
  this lab at flux v1.80.0 (stuttgart-things/flux#514) -- see [`../machinery-hv/cicd-platform.yaml`](../machinery-hv/cicd-platform.yaml).

## What is here

| File | Listed | Objects |
|---|---|---|
| `environmentconfigs.yaml` | yes | `harvestervm-sthings-lab`, `ansible-run-defaults`, `rancher-cluster-join-sthings-lab` |
| `providerconfigs.yaml` | yes | provider-kubernetes `harvester`, `rancher-mgmt` -- inert until step A |
| `openbao-pki-source-ca.yaml` | yes | `default/openbao-pki-source-ca`, the OpenBao root the Platform copies onto built clusters |
| `vault-provider-configs.yaml` | **no** | provider-vault `vault`, `vault-cluster-secrets`, `vault-kubeconfig-writer` |
| `cluster-vault-sthings-lab.yaml` | **no** | the OpenBao policy mapping for `environmentConfig: sthings-lab` |
| `appsecretprofiles.yaml` | **no** | `homerun2`, `schmetterpause`, `zaehlwerk`, `tabletennis` |

## What is missing, in order

Unlisted files stay unlisted until their step is done. Every one of them fails
**silently** when applied early -- a role naming a missing policy logs in and is
granted nothing.

**A. Encrypted Secrets** in `secrets/`, each `dagger … sops encrypt` like the rest
of this repo:

| File | Secret | Keys | Source |
|---|---|---|---|
| `ansible-credentials.enc.yaml` | `tekton-ci/ansible-credentials` | `ANSIBLE_USER`, `ANSIBLE_PASSWORD` | the golden image's cloud-init login; crossplane-mgmt carries the same Secret |
| `harvester-kubeconfig.enc.yaml` | `crossplane-system/harvester-kubeconfig` | `kubeconfig` | `~/.kube/harvester` |
| `rancher-mgmt-kubeconfig.enc.yaml` | `crossplane-system/rancher-mgmt-kubeconfig` | `kubeconfig` | `~/.kube/platform.sthings.lab` -- a scoped Rancher token rather than the admin kubeconfig would be better |

`tekton-ci` must exist before the first one applies; the tekton component
creates it.

**B. OpenBao objects**, in `../platform/openbao` (Terraform, beside `approle.tf`):

- KV mounts `kubeconfigs`, `homerun2`, `schmetterpause`, `observability`
- policies `read-{homerun2,schmetterpause,observability}-clusters`,
  `write-{homerun2,schmetterpause,observability}-clusters` (one path segment,
  `_` entries denied -- see stuttgart-things#3017), `write-kubeconfigs`
- the shared entry `homerun2/_git-pat`

**C. AppRoles** on that OpenBao, and their `credentials` JSON encrypted into
`secrets/`:

| AppRole | Policies | ProviderConfig |
|---|---|---|
| k8s-auth bootstrap | may create Kubernetes auth mounts and roles (the scope of `crossplane-auth-admin`) | `vault` |
| cluster-secrets writer | `write-*-clusters` | `vault-cluster-secrets` |
| kubeconfig writer | `write-kubeconfigs` | `vault-kubeconfig-writer` |
| kubeconfig reader | read on `kubeconfigs/` | provider-kubeconfig (see below) |

Plus the tfvars twins in `default` the OpenTofu Workspaces read
(`vault-approle`, `vault-cluster-secrets-writer`, `vault-kubeconfig-writer`).

**D. AppSecretProfiles** -- list them once B has the mounts they name.

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

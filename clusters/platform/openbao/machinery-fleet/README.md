# OpenBao objects for the `machinery-hv` fleet

What the Crossplane management cluster `machinery-hv` needs on the OpenBao that
runs on `platform`: the KV mounts built clusters keep their kubeconfigs and app
secrets in, the policies over them, and the AppRoles machinery-hv logs in with.
The consumer side is [`clusters/machinery-hv-fleet-state`](../../../machinery-hv-fleet-state/README.md).

A root of its own, with its own state (`tfstate-default-openbao-machinery-fleet`
in `cert-manager` on `platform`). `../` holds the PKI, platform's auth mount and
the `crossplane` AppRole that every VaultK8sAuth on crossplane-mgmt uses. Nothing
planned here can touch them.

| Object | Name(s) | For |
|---|---|---|
| KV v2 mounts | `kubeconfigs`, `homerun2`, `schmetterpause`, `observability` | the built clusters' entries, one path segment each |
| Policies | `read-{homerun2,schmetterpause,observability}-clusters` | a built cluster's ESO, via `cluster-vault-sthings-lab` |
| | `write-{…}-clusters` | the writer; `_` entries are read-only to it |
| | `write-kubeconfigs`, `read-kubeconfigs` | kubeconfig upload / read-back |
| AppRoles | `machinery-hv-cluster-secrets-writer`, `-kubeconfig-writer`, `-kubeconfig-reader` | provider-vault / the join play / provider-kubeconfig |
| secret_id | on the existing `crossplane` role | provider-vault `vault`: mounting the built clusters' auth backends |

Names follow the LabUL fleet, so a ClusterStack written for LabDA's machinery
cluster reads the same here.

## Apply

```bash
cd clusters/platform/openbao/machinery-fleet
export VAULT_TOKEN=$(tr -d '[:space:]' < ~/.vaulttoken)
terraform init        # see below if the registry is unreachable
terraform plan -out=tfplan
terraform apply tfplan
./render-fleet-secrets.sh     # encrypts the credentials into the fleet state
```

On 2026-09-24 the registry was unreachable from the workstation (IPv4 and IPv6
timed out), so the provider came from the sibling root's cache. It is the same
`hashicorp/vault` v5.12.0:

```bash
terraform init -plugin-dir=../../../machinery-hv/openbao/.terraform/providers
```

`Plan: 19 to add, 0 to change, 0 to destroy` → `Apply complete! Resources: 19 added`.

## Proven with a real login, not with the policy text

Each AppRole logged in and was tried against what it must and must not reach
(2026-09-24, all as expected; the probe entries were deleted afterwards):

| AppRole | Request | Result |
|---|---|---|
| cluster-secrets-writer | write `homerun2/zz-probe` | 200 |
| | write `homerun2/_zz-probe` (shared) | 403 |
| | write `homerun2/a/b` (two segments) | 403 |
| | write `kubeconfigs/…` | 403 |
| kubeconfig-writer | write `kubeconfigs/zz-probe` | 200 |
| kubeconfig-reader | read `kubeconfigs/zz-probe` | 200 |
| | write `kubeconfigs/…` | 403 |
| | read `homerun2/…` | 403 |
| crossplane (new secret_id) | `GET sys/auth` | 200 |
| | read `homerun2/…` | 403 |

## Not here

- **`homerun2/_git-pat`**, the shared entry the `homerun2` AppSecretProfile's
  `githubToken` reads. It needs a real GitHub token, and whose token that is,
  is a decision for a person, not for Terraform. Seed it by hand.
- **Rotation** is explicit: `terraform taint 'vault_approle_auth_backend_role_secret_id.fleet["…"]'`,
  apply, rerun `render-fleet-secrets.sh C`, commit. secret_ids do not expire
  (`secret_id_ttl = 0`), for the reason `../openbao.tf` gives.

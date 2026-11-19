# OpenBao objects for the `machinery-hv` fleet

What the Crossplane management cluster `machinery-hv` needs on the OpenBao that
runs on `platform`: the KV mounts built clusters keep their kubeconfigs and app
secrets in, the policies over them, and the AppRoles machinery-hv logs in with.
The consumer side is [`clusters/machinery-hv/fleet-state`](../../../machinery-hv/fleet-state/README.md).

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
| | `write-clusterscope-kubeconfigs` | on the kubeconfig-writer: a ClusterStack's `clusterscope-reader` Workspace writes `clusterscope/<cluster>` (harvester#753) |
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

## clusterscope reader kubeconfigs (harvester#753)

xplane-cluster 0.28.0 can write a cluster's READ-ONLY kubeconfig for
clusterscope itself (`spec.clusterscope.reader.enabled: true` on the
ClusterStack), instead of `../platform-eso/seed-clusterscope-kubeconfig.sh`.
Its Workspace logs in with the **kubeconfig-writer** AppRole -- the
`default/vault-kubeconfig-writer` Secret the `kubeconfig-vault` Workspace
already uses -- so this root only adds the policy
`write-clusterscope-kubeconfigs` to that role. No new secret_id, nothing to
re-render: `render-fleet-secrets.sh` is not involved.

Expected plan: `vault_policy.write_clusterscope` added, the
`machinery-hv-kubeconfig-writer` role's `token_policies` changed in place
(its secret_id stays). The `clusterscope` mount itself is
`../platform-eso`'s and must exist first.

To prove before the first opt-in (same method as above, probe entry deleted
afterwards):

| AppRole | Request | Expected |
|---|---|---|
| kubeconfig-writer | write `clusterscope/zz-probe` + its metadata | 200 |
| | write `clusterscope/a/b` (two segments) | 403 |
| | read `kubeconfigs/<cluster>` | 200 (unchanged) |

## Shared entries (`_<name>`) from SOPS

`shared.tf` writes the shared `_` entries that are plain configuration, not a
person's credential, from `shared.tfvars.sops.json` (harvester#523):

| Entry | Property | Read by |
|---|---|---|
| `homerun2/_teams-webhook` | `teamsWebhookUrl` | notification-catcher on every built cluster (`shared: teams-webhook` in the `homerun2` AppSecretProfile), Teams channel `harvester-apps` |
| `observability/_omni-pitcher` | `alertmanager-webhook-token` | kube-prometheus-stack's Alertmanager on every built cluster with the `observability` profile (derived annotation `alert-webhook-secret-key: _omni-pitcher`). The bearer token of homerun2-dev's omni-pitcher, copied from `HOMERUN2_OMNI_PITCHER_AUTH_TOKEN` in `clusters/homerun2-dev/homerun2-secrets-subst.enc.yaml` (harvester#753). Rotating that token means updating both files |

```bash
cd clusters/platform/openbao/machinery-fleet
# add or change a value
# --value-stdin takes a JSON value, so quote it with jq; read -rs keeps it off
# the screen and out of the history
read -rs URL; printf '%s' "$URL" | jq -Rs . | sops set --value-stdin shared.tfvars.sops.json \
  '["shared_entries"]["homerun2/_teams-webhook"]["data"]["teamsWebhookUrl"]'; unset URL
# (the first time, create the parent first:
#  echo '{"data":{}}' | sops set --value-stdin shared.tfvars.sops.json '["shared_entries"]["homerun2/_teams-webhook"]')

# observability/_omni-pitcher: copied SOPS -> SOPS, never on screen
sops -d --extract '["stringData"]["HOMERUN2_OMNI_PITCHER_AUTH_TOKEN"]' \
    ../../../homerun2-dev/homerun2-secrets-subst.enc.yaml \
  | jq -Rs '{data:{"alertmanager-webhook-token": .}}' \
  | sops set --value-stdin shared.tfvars.sops.json '["shared_entries"]["observability/_omni-pitcher"]'

export VAULT_TOKEN=…   # as for the rest of this root
sops exec-file --filename shared.tfvars.json shared.tfvars.sops.json 'terraform plan  -var-file={}'
sops exec-file --filename shared.tfvars.json shared.tfvars.sops.json 'terraform apply -var-file={}'
```

> [!IMPORTANT]
> **Every run of this root needs the `-var-file` now**, including AppRole
> rotation. `shared_entries` has no default on purpose: with an empty default, a
> plain `terraform apply` would delete every shared entry. `--filename` must
> end in `.json`, or Terraform parses the decrypted file as HCL.

## Not here

- **`homerun2/_git-pat`**, the shared entry the `homerun2` AppSecretProfile's
  `githubToken` reads. It needs a real GitHub token, and whose token that is,
  is a decision for a person, not for Terraform. Seed it by hand.
- **The `rancher-mgmt` kubeconfig** is not an AppRole: step `R` of
  `render-fleet-secrets.sh` builds it from the token of the ServiceAccount
  `crossplane-machinery` on platform (`../../crossplane-machinery-access.yaml`).
  Rotate it by deleting `crossplane-machinery/crossplane-machinery-token` on
  platform, waiting for the new token, `./render-fleet-secrets.sh R`, commit.
- **Rotation** is explicit: `terraform taint 'vault_approle_auth_backend_role_secret_id.fleet["…"]'`,
  apply, rerun `render-fleet-secrets.sh C`, commit. secret_ids do not expire
  (`secret_id_ttl = 0`), for the reason `../openbao.tf` gives.

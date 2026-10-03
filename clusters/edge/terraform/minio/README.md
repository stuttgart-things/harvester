# clusters/edge/terraform/minio

MinIO configuration for the edge node: the bucket for schmetterpause's CNPG
backups, a user `schmetterpause-cnpg`, and a policy that allows that user exactly
that bucket (harvester#364, phase 1b). MinIO itself is deployed by Flux
([`../../apps/minio.yaml`](../../apps/minio.yaml)). Flux never reads this
directory ([`../../.sourceignore`](../../.sourceignore)).

| | |
|---|---|
| Provider | `aminueza/minio` ~> 3.44 |
| Endpoint | `minio.edge-tt-test1.4sthings.tiab.ssc.sva.de:443`, through the Gateway, TLS verified against the edge root CA ([`edge-root-ca.crt`](./edge-root-ca.crt), a copy of `../../edge-root-ca.crt`) |
| State | `backend "kubernetes"`, Secret `minio/tfstate-default-minio-edge` on the node |
| Inputs | `minio_user`, `minio_password` (root), `cnpg_secret_key`, all from `../../apps/edge-secrets-subst.enc.yaml` (`MINIO_ADMIN_USER`, `MINIO_ADMIN_PASSWORD`, `MINIO_CNPG_PASSWORD`) |
| Bucket | adopted from the chart's `defaultBuckets` with an `import` block; Terraform is its only owner afterwards |

## Run (dagger, the default)

```bash
cd ~/projects/harvester
umask 077
sops -d --output-type json clusters/edge/apps/edge-secrets-subst.enc.yaml \
  | jq '.stringData | {minio_user: .MINIO_ADMIN_USER, minio_password: .MINIO_ADMIN_PASSWORD, cnpg_secret_key: .MINIO_CNPG_PASSWORD}' \
  > /tmp/edge-minio.tfvars.json

env -u SSH_AUTH_SOCK dagger call -m github.com/stuttgart-things/dagger/terraform@v0.134.0 \
  execute \
  --terraform-dir clusters/edge/terraform/minio \
  --operation apply \
  --secret-json-variables file:///tmp/edge-minio.tfvars.json \
  --kube-config file://$HOME/.kube/edge-tt-test1 \
  --progress plain

shred -u /tmp/edge-minio.tfvars.json
```

The module has no `plan` operation. To look first, run Terraform locally
against the same state:

```bash
cd clusters/edge/terraform/minio
terraform init -backend-config=config_path=$HOME/.kube/edge-tt-test1
terraform plan -var-file=/tmp/edge-minio.tfvars.json
```

`**/terraform.tfvars.json` is gitignored, but keep the decrypted file outside
the repo anyway, and shred it.

## Last run

2026-10-03: `Apply complete! Resources: 1 imported, 3 added, 0 changed, 0
destroyed.` (bucket imported; user, policy and attachment created). A second
`plan` showed no changes.

**Run with local Terraform, not dagger.** On this workstation the Dagger engine
cannot resolve `*.4sthings.tiab.ssc.sva.de`. The host resolves it through
split DNS (systemd-resolved: `~4sthings.tiab.ssc.sva.de` → 10.100.136.115),
but the engine's own resolver (10.87.0.1) does not know about the split. The
dagger run waited 2 minutes on the import, then failed with `could not read
minio bucket`. Going by IP does not help, because the Gateway routes by SNI.
Until the engine resolves the zone (engine DNS config, or running on a host
without split DNS), use the local `terraform` commands above with `apply`.

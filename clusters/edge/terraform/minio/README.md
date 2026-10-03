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
# the host's resolvers: *.4sthings.tiab.ssc.sva.de resolves only through
# them (split DNS), not through the Dagger engine's own resolver
printf 'nameserver 10.100.136.115\nnameserver 10.100.101.5\n' > /tmp/edge-resolv.conf

env -u SSH_AUTH_SOCK dagger call -m github.com/stuttgart-things/dagger/terraform@v0.135.0 \
  execute \
  --terraform-dir clusters/edge/terraform/minio \
  --operation apply \
  --refuse-destroy \
  --secret-json-variables file:///tmp/edge-minio.tfvars.json \
  --kube-config file://$HOME/.kube/edge-tt-test1 \
  --resolv-conf /tmp/edge-resolv.conf \
  --progress plain

shred -u /tmp/edge-minio.tfvars.json
```

- `--refuse-destroy`: the plan is applied only if it deletes or replaces
  nothing. That matters for a bucket with backups in it.
- `--resolv-conf` (module v0.135.0, stuttgart-things/dagger#398). Without
  it the engine cannot resolve the MinIO host on a workstation with split DNS
  (systemd-resolved `~4sthings.tiab.ssc.sva.de` → 10.100.136.115). The first
  dagger run hung for 2 minutes on the import and failed with `could not read
  minio bucket`. The alternative for a single name is `--bind-service
  tcp://10.100.136.223:443 --bind-service-alias minio.<domain>`; the two
  options are exclusive.
- Dagger caches the exec: an unchanged rerun prints the result of the previous
  one without running Terraform. To force a real run, change an argument, e.g.
  `--variables cnpg_bucket=schmetterpause-cnpg`.

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

2026-10-03, two runs:

1. **First apply, local Terraform 1.14.8.** The Dagger engine could not
   resolve the host yet. Result: `Apply complete! Resources: 1 imported, 3
   added, 0 changed, 0 destroyed.` (bucket imported; user, policy and
   attachment created).
2. **Rerun, dagger/terraform v0.135.0 (Terraform 1.16.5) with `--resolv-conf`
   and `--refuse-destroy`.** All four resources refreshed live: `No changes.
   ... Apply complete! Resources: 0 added, 0 changed, 0 destroyed.`

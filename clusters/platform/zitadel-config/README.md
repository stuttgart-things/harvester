# ZITADEL config (platform) — portal, Backstage, claim-machinery and app OIDC clients

Declarative ZITADEL setup of the Harvester lab IdP at
`https://zitadel.platform.sthings.lab` (Flux: `apps-platform` → `zitadel` on
this cluster, #560). Since #680 it is the **third lab of the shared root** of
stuttgart-things/stuttgart-things#4612 (LabUL
`clusters/labul/vsphere/infra-sthings/zitadel-portal-config`, LabDA
`clusters/labda/vsphere/sthings-infra/zitadel-config`).

## Same code as LabUL/LabDA (#680)

`main.tf`, `variables.tf` and `outputs.tf` are the files of the two vSphere
roots; the only change is the module `source`: `git::…?ref=<commit>` instead
of the relative path (pinned -- a change there must not reach this instance
unreviewed). Bump the ref and copy the three files together.

| File | What |
|---|---|
| `lab.auto.tfvars` | `zitadel_domain`, `portals`, `oidc_apps`, `backstages`, `claim_machinery_machine_users`, `claim_machinery_portals`, `vaults`, `argocds` |
| `users.auto.tfvars` | `users`, `backstage_roles`, `vault_roles`, `argocd_roles` |
| `backend.tf` | where the state lives |

**Harvester-only, the exception to "only the tfvars differ"** -- MinIO and
Grafana, wired before the shared root existed:

| File | What |
|---|---|
| [`harvester-extras.tf`](./harvester-extras.tf) + [`apps.auto.tfvars`](./apps.auto.tfvars) | the projects/clients `minio`, `minio-readonly`, `grafana` (#574, #719) |
| [`moved.tf`](./moved.tf) | `module.zitadel_portal.*` → `module.users` / `module.portal` (#680); `argocd` → `module.argocd` (#677); same IDs |

Since #677/#719 there is **no `groups` claim any more** (`groups-claim.tf`,
Actions v1, removed): Argo CD reads `argocd_roles` (action `argocdRoles` of the
shared root, `argocds` in `lab.auto.tfvars`), Grafana reads ZITADEL's role map
`urn:zitadel:iam:org:project:roles` (JMESPath in `../infra.yaml`), MinIO has
one client per policy (`ROLE_POLICY`, two login buttons, `../apps/minio.yaml`),
OpenBao reads the role map with bound claims (`../openbao/oidc.tf`).

## What it creates

In the default org `ZITADEL`:

- `module.users`: the org lookup and the **users** of `users.auto.tfvars`
  (a copy of the vSphere labs' list -- keep them in step)
- `module.portal`: **project** `sthings-portal` (role check, role
  assertion), roles `portal-admin` / `portal-user`, one web client per
  `portals` entry -- `homerun2-dev` (`https://portal.homerun2-dev.sthings.lab`,
  live) and `machinery-portal` (`https://machinery-portal.platform.sthings.lab`,
  #681, not deployed yet): redirect `/auth/callback`, post-logout
  `/auth/login`
- `module.backstage`: **project** `sthings-backstage`, roles
  `backstage-platform` / `backstage-developer` (grants from `backstage_roles`),
  clients `backstage` (`https://backstage.platform.sthings.lab`, #675),
  `claims-cli` (native, device flow, JWT), `machinery-portal-machinery-hv`
  (`https://machinery-portal.machinery-hv.sthings.lab`, #681), and the
  machine user `machinery-order-service` (client credentials, JWT,
  `backstage-platform`). claim-machinery-api's audience is this project
  (output `claim_machinery_audience`, #676)
- `harvester-extras.tf`: `argocd`, `minio`, `grafana` (below)

Outputs: those of the shared root (`issuer`, `org_id`, `user_ids`,
`project_id`, `client_ids` / `client_secrets`, `backstage_*`,
`claim_machinery_*`, `vault_*`, `argocd_*`) plus `app_client_ids` /
`app_client_secrets` of harvester-extras.tf.

---

## Bootstrap (no console)

The Flux component creates everything Terraform needs: the setup job makes
the machine user **`terraform`** with **IAM_OWNER** and writes its JSON key to
the Secret `terraform` in the `zitadel` namespace.

### 1. Fetch the key -- OUTSIDE the repo

```bash
export KUBECONFIG=/home/sthings/.kube/platform.sthings.lab
mkdir -p ~/.config/zitadel
(umask 077; kubectl -n zitadel get secret terraform \
  -o jsonpath='{.data.terraform\.json}' | base64 -d \
  > ~/.config/zitadel/terraform-key-harvester.json)
jq -r '.type, .userId' ~/.config/zitadel/terraform-key-harvester.json   # serviceaccount, <id>
```

### 2. The CA for the TLS handshake

ZITADEL is served under the gateway's wildcard certificate from the OpenBao
PKI (`CN=sthings.lab`). The provider's `insecure` means "http", not "skip
verify", so Go has to trust that CA via `SSL_CERT_FILE`. The root CA is
committed in `../openbao-pki-ca.yaml`:

```bash
yq '.data."ca.crt"' ../openbao-pki-ca.yaml | base64 -d > ~/.config/zitadel/ca-harvester.pem
openssl x509 -in ~/.config/zitadel/ca-harvester.pem -noout -subject      # CN=sthings.lab
curl -s -o /dev/null -w '%{http_code}\n' --cacert ~/.config/zitadel/ca-harvester.pem \
  https://zitadel.platform.sthings.lab/.well-known/openid-configuration   # 200
```

---

## Apply

```bash
cd clusters/platform/zitadel-config

export KUBECONFIG=/home/sthings/.kube/platform.sthings.lab          # state backend
export TF_VAR_zitadel_jwt_profile_file=$HOME/.config/zitadel/terraform-key-harvester.json
export SSL_CERT_FILE=$HOME/.config/zitadel/ca-harvester.pem

# users and their roles come from users.auto.tfvars (no passwords there);
# initial passwords are write-only (provider v3.8.7): never in the state, so
# note them down -- they must be changed at the first login
export TF_VAR_user_initial_passwords="$(jq -nc --arg pw '<initial password>' \
  '[ "sthings","indy","tommy","mcfly","mcclane","fmcguire","rdevaney","someara" ] | map({(.): $pw}) | add')"

terraform init
terraform plan      # after #680: No changes
terraform apply

terraform output -raw issuer
terraform output -json client_ids     | jq -r '."homerun2-dev"'
terraform output -json client_secrets | jq -r '."homerun2-dev"'   # sensitive -- don't paste
```

`initial_password` is write-only and used at creation only: `terraform show`
returns `null` for it, there is no way to look it up afterwards. To give an
existing user a new initial password (again with a forced change at the first
login), replace it:
`terraform apply -replace='module.users.zitadel_human_user.user["<name>"]'`
(its grant is replaced with it).

### One password for all users, no forced change

The module always sets `initial_skip_password_change = false`. To set a
password that the users keep, [`set-passwords.py`](./set-passwords.py) calls
the ZITADEL API directly: it logs in as the machine user `terraform` (key and
CA from the bootstrap above, PyJWT), reads the user IDs from
`terraform show -json` and sets the same password for every
`zitadel_human_user` with `changeRequired: false` (`POST /v2/users/{id}/password`).
The password is asked twice on the terminal and ends up neither in the repo
nor in the state.

```bash
python3 clusters/platform/zitadel-config/set-passwords.py   # <name>: ok per user
```

ZITADEL's default password age policy has no expiry; the default complexity
policy (8+ chars, upper, lower, number, symbol) applies. Terraform does not
undo it (`initial_password` is in `ignore_changes`); only a `-replace` makes the
password an initial one again.

### Common pitfalls

| Symptom | Cause | Fix |
|---|---|---|
| `failed to start zitadel client: open <token>: file name too long` | `TF_VAR_zitadel_jwt_profile_file` set to the key's content | Point it at the file path |
| `x509: certificate signed by unknown authority` | `SSL_CERT_FILE` unset or not the `sthings.lab` CA | Step 2 |
| `credentials: cannot check peer: missing selected ALPN property`; the console shows `[unknown] missing trailer` | Cilium Gateway without `gatewayAPI.enableAlpn` / `enableAppProtocol`: no `h2` on the TLS listener, HTTP/1.1 to ZITADEL's h2c port | Both `true` in the Cilium values (deploy-configure-rke default since #35); stopgap for Terraform: `export GRPC_ENFORCE_ALPN_ENABLED=false` |
| `issuer does not match` | `port = 443` or `insecure = true` on the provider | Neither is set here; do not add them |
| `namespaces "zitadel" not found` at init | The Flux component is not deployed yet | Deploy first; the state lives in that namespace |
| Plan wants to destroy all users | Run from a checkout without `users.auto.tfvars` | Apply from a branch/commit that has it |
| Login stops right after the password with a project / grant error | `project_role_check`: the user has no role on `sthings-portal` | Add the user to `users.auto.tfvars` with a role |

---

## Further apps (harvester#574)

[`harvester-extras.tf`](./harvester-extras.tf) (until #680 `apps.tf`) adds OIDC clients next to the portal, from
[`apps.auto.tfvars`](./apps.auto.tfvars) -- per app:

- **project** `<app>` with role check (no role on it, no login) and role
  assertion; its **roles**, keys prefixed with the app name (`argocd-admin`)
- **OIDC web app** `<app>`: redirect/post-logout paths on its base URL, code
  flow, basic auth, roles and profile claims in the ID token
- **grants** for users of `users.auto.tfvars` (ids from the module output
  `user_ids`)

Roles reach the apps through ZITADEL's role map in the ID token (no
`groups` claim since #719), see the table above.

**Every app keeps its local admin** -- these clients add a login, they replace
none (harvester#574).

```bash
terraform output -json app_client_ids     | jq -r '.grafana'
terraform output -json app_client_secrets | jq -r '.grafana'   # sensitive -- don't paste
```

| App | URL | Roles | Local fallback |
|---|---|---|---|
| `minio` | `https://artifacts-console.platform.sthings.lab` | `minio-admin` → `ROLE_POLICY` minio-admin, button "ZITADEL (admin)" | root user |
| `minio-readonly` | same | `minio-readonly` → `ROLE_POLICY` minio-readonly, button "ZITADEL (read-only)" | root user |
| `grafana` | `https://grafana.platform.sthings.lab` | `grafana-admin` (Admin), `grafana-readonly` (Viewer) | `admin` |

### Wiring ArgoCD

`../apps/argocd-platform.yaml` patches the HelmRelease `argocd-deployment`:
`url`, RBAC (`argocd-admin` => `role:admin`, `argocd-reader` =>
`role:readonly`, scopes `[argocd_roles]`, #677) and `oidc.config` via `valuesFrom` from the
SOPS Secret `argocd-oidc-zitadel` in `argocd` (`../apps/argocd-oidc-zitadel.enc.yaml`),
key `values.yaml`: a values document with `configs.cm."oidc.config"` (no
`targetPath` -- that parses as `--set` and breaks on commas).
It holds the client secret literally -- a `$secret:key` reference would not
survive the two Flux substitutions. Make it after an apply that changed the
argocd client:

```bash
umask 077
CID=$(terraform output -json argocd_client_ids | jq -r '.argocd')
terraform output -json argocd_client_secrets | jq -j '.argocd' > /dev/shm/argocd-cs
{ echo "name: ZITADEL"
  echo "issuer: https://zitadel.platform.sthings.lab"
  echo "clientID: \"$CID\""
  echo "clientSecret: \"$(cat /dev/shm/argocd-cs)\""
  echo "requestedScopes: [openid, profile, email]"
  echo "rootCA: |"; yq '.data."ca.crt"' ../openbao-pki-ca.yaml | base64 -d | sed 's/^/  /'
} > /dev/shm/argocd-oidc.config
yq -n '.configs.cm."oidc.config" = load_str("/dev/shm/argocd-oidc.config")' > /dev/shm/argocd-values.yaml
kubectl create secret generic argocd-oidc-zitadel -n argocd \
    --from-file=values.yaml=/dev/shm/argocd-values.yaml --dry-run=client -o yaml \
  | sops --encrypt --age age19vgzvmpt9tdlcsu8rzaacj397yz8gguz38nsmuy6eeelt5vjsyms542xtm \
      --encrypted-regex '^(data|stringData)$' --input-type yaml --output-type yaml /dev/stdin \
  > ../apps/argocd-oidc-zitadel.enc.yaml
shred -u /dev/shm/argocd-cs /dev/shm/argocd-oidc.config /dev/shm/argocd-values.yaml
```

Check both logins: "LOG IN VIA ZITADEL" with a ZITADEL user, and the local
`admin` with the password from `argocd-secrets.enc.yaml`.

## Wiring into the portal (homerun2-dev)

`clusters/homerun2-dev` (#560): issuer `https://zitadel.platform.sthings.lab`,
client ID from `client_ids`, allowed groups `portal-admin,portal-user`, the
client secret as key `oidc-client-secret` of the portal's SOPS Secret. The
redirect URL must be exactly
`https://portal.homerun2-dev.sthings.lab/auth/callback`.

## Rotating the client secret

```bash
terraform apply -replace='module.portal.zitadel_application_oidc.app["homerun2-dev"]'
```

A new app: client ID **and** secret change. Update both in the portal.

## State

Kubernetes Secret `tfstate-default-zitadel-config` in the `zitadel` namespace
on platform: it holds the client secrets in cleartext (user passwords are
write-only and not in it).
Removing the `zitadel` component from `apps-platform` deletes the namespace --
and this state with it.
The nightly backup below keeps a copy of it.

---

## Backup and restore

[`../apps/zitadel-backup.yaml`](../apps/zitadel-backup.yaml): CronJob
`zitadel-backup` in `zitadel`, 02:30 Europe/Berlin. It writes
`<UTC timestamp>/zitadel.dump` (`pg_dump -Fc` of the database `zitadel`,
checked with `pg_restore --list`) and `<UTC timestamp>/tfstate-zitadel-config.gz`
(this Terraform state, gzip as the backend stores it) with rclone to every
target in its `BACKUP_TARGETS` (#753):

| Remote | Where | Bucket | Kept | Credentials |
|---|---|---|---|---|
| `platform` | platform's MinIO, same machine | `platform-zitadel-backup` | 14 days, deleted by the job | `../apps/zitadel-backup-secrets.enc.yaml`; bucket and user from [`clusters/machinery-hv/xrs/platform-zitadel-backup.yaml`](../../machinery-hv/xrs/platform-zitadel-backup.yaml) |
| `homerun2dev` | MinIO on homerun2-dev (Harvester host): **off-host** | `platform-zitadel-backup` | 30 days, bucket lifecycle; versioned; the job's user cannot delete | `../apps/zitadel-backup-target-homerun2-dev.enc.yaml`; bucket, policy and user from [`clusters/homerun2-dev/minio.yaml`](../../homerun2-dev/minio.yaml) |

Each target is an rclone remote configured from `RCLONE_CONFIG_<REMOTE>_*`
environment variables; adding one (Azure Blob is planned, with an rclone
`crypt` remote on top) is a Secret, an `envFrom` line and a `BACKUP_TARGETS`
line -- the CronJob's header comment has the recipe.

**The masterkey is not in it.** It is `ZITADEL_MASTERKEY` in
`../apps/zitadel-secrets.enc.yaml` (git, SOPS) and must be the same on the
instance a dump is restored into -- without it the encrypted data in the dump
(keys, secrets) is lost.

The platform copy covers a deleted namespace, a broken database and a bad
upgrade; the homerun2-dev copy also the loss of the platform machine.

### The bucket keys (once, after the bucket exists)

The keys live in Secret `default/platform-zitadel-backup` on machinery-hv and go
into platform as `../apps/zitadel-backup-secrets.enc.yaml` (Secret
`zitadel-backup-s3`):

```bash
cd /home/sthings/harvester
kubectl --kubeconfig ~/.kube/machinery-hv -n default get secret platform-zitadel-backup -o json \
  | jq '{apiVersion: "v1", kind: "Secret", type: "Opaque",
         metadata: {name: "zitadel-backup-s3", namespace: "zitadel"},
         data: {AWS_ACCESS_KEY_ID: .data.AWS_ACCESS_KEY_ID,
                AWS_SECRET_ACCESS_KEY: .data.AWS_SECRET_ACCESS_KEY}}' \
  | yq -P \
  | sops --encrypt --age age19vgzvmpt9tdlcsu8rzaacj397yz8gguz38nsmuy6eeelt5vjsyms542xtm \
      --encrypted-regex '^(data|stringData)$' --input-type yaml --output-type yaml /dev/stdin \
  > clusters/platform/apps/zitadel-backup-secrets.enc.yaml
grep -c 'ENC\[' clusters/platform/apps/zitadel-backup-secrets.enc.yaml   # 3 (2 keys + the sops mac)
```

### Check a run

```bash
export KUBECONFIG=~/.kube/platform.sthings.lab
kubectl -n zitadel create job --from=cronjob/zitadel-backup zitadel-backup-manual
kubectl -n zitadel logs job/zitadel-backup-manual -c dump
kubectl -n zitadel logs job/zitadel-backup-manual -c upload    # "== <target> ok" per target, then its timestamps
kubectl -n zitadel delete job zitadel-backup-manual
```

### Fetch a dump

```bash
kubectl --kubeconfig ~/.kube/platform.sthings.lab -n minio port-forward svc/minio-deployment 9000 &
eval "$(kubectl --kubeconfig ~/.kube/machinery-hv -n default get secret platform-zitadel-backup -o json \
  | jq -r '.data | "export MC_HOST_zb=http://\(.AWS_ACCESS_KEY_ID|@base64d):\(.AWS_SECRET_ACCESS_KEY|@base64d)@localhost:9000"')"
mc ls zb/platform-zitadel-backup/
mc cp --recursive zb/platform-zitadel-backup/<timestamp>/ /dev/shm/zitadel-restore/
```

Platform gone: the off-host copy on homerun2-dev, with the root login (the
backup user would do too, it may read):

```bash
eval "$(sops -d clusters/homerun2-dev/minio-secrets.enc.yaml \
  | yq -r '"export MC_HOST_zb=https://" + .stringData.MINIO_ADMIN_USER + ":" + .stringData.MINIO_ADMIN_PASSWORD + "@minio.homerun2-dev.sthings.lab"')"
mc ls zb/platform-zitadel-backup/
mc cp --recursive zb/platform-zitadel-backup/<timestamp>/ /dev/shm/zitadel-restore/
```

`mc` verifies against the system CAs; the sthings.lab root must be one of them
(or in `~/.mc/certs/CAs/`).

### Restore the database

Into the running instance (database broken, bad upgrade), or after the
namespace was recreated by Flux (same masterkey from SOPS; ZITADEL's setup
created a fresh database, the dump replaces it):

```bash
export KUBECONFIG=~/.kube/platform.sthings.lab
flux suspend ks zitadel                         # keeps Flux from scaling back up
flux suspend hr zitadel -n zitadel
kubectl -n zitadel scale deploy zitadel zitadel-login --replicas=0

kubectl -n zitadel cp /dev/shm/zitadel-restore/zitadel.dump zitadel-postgresql-0:/tmp/zitadel.dump
kubectl -n zitadel exec zitadel-postgresql-0 -- bash -c \
  'PGPASSWORD="$(cat "$POSTGRES_POSTGRES_PASSWORD_FILE")" pg_restore -U postgres -d zitadel --clean --if-exists --no-owner --role=zitadel /tmp/zitadel.dump; rm /tmp/zitadel.dump'

kubectl -n zitadel scale deploy zitadel zitadel-login --replicas=1
flux resume hr zitadel -n zitadel               # no drift detection: does not scale by itself
flux resume ks zitadel
curl -s -o /dev/null -w '%{http_code}\n' https://zitadel.platform.sthings.lab/debug/healthz   # 200
```

Then log in with a ZITADEL user and run `terraform plan` here: no changes.

### Restore the Terraform state

Only when the Secret is gone (namespace deleted). The backend finds it by name
and labels:

```bash
kubectl -n zitadel create secret generic tfstate-default-zitadel-config \
  --from-file=tfstate=/dev/shm/zitadel-restore/tfstate-zitadel-config.gz
kubectl -n zitadel label secret tfstate-default-zitadel-config \
  app.kubernetes.io/managed-by=terraform tfstate=true \
  tfstateSecretSuffix=zitadel-config tfstateWorkspace=default
kubectl -n zitadel annotate secret tfstate-default-zitadel-config encoding=gzip
terraform plan   # after the database restore: no changes
shred -u /dev/shm/zitadel-restore/*
```

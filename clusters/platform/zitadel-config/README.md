# ZITADEL config (platform) — sthings-portal OIDC clients

Declarative ZITADEL setup for sthings-portal's OIDC login against the
Harvester lab IdP at `https://zitadel.platform.sthings.lab` (Flux:
`apps-platform` → `zitadel` on this cluster, #560). A root over the module
[`terraform/modules/zitadel-portal`](https://github.com/stuttgart-things/stuttgart-things/tree/main/terraform/modules/zitadel-portal)
of the vSphere labs (stuttgart-things/stuttgart-things#4118), pinned to a
commit in `main.tf`.

## What it creates

In the default org `ZITADEL`:

- **Project** `sthings-portal` with role check (no role, no login) and role
  assertion; **roles** `portal-admin`, `portal-user`
- **OIDC web app** per entry of `portals`, by default
  `homerun2-dev` → `https://portal.homerun2-dev.sthings.lab`: redirect
  `/auth/callback`, post-logout `/auth/login`, code flow, basic auth, roles +
  `preferred_username` in the ID token
- **Users** with grants from `users.auto.tfvars` (a copy of the vSphere labs'
  list -- keep them in step)

Outputs `issuer`, `client_ids`, `client_secrets` (maps by portal name),
`project_id`, `org_id`.

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
terraform plan      # 1 project, 2 roles, 1 OIDC app, 8 users, 8 grants
terraform apply

terraform output -raw issuer
terraform output -json client_ids     | jq -r '."homerun2-dev"'
terraform output -json client_secrets | jq -r '."homerun2-dev"'   # sensitive -- don't paste
```

`initial_password` is write-only and used at creation only: `terraform show`
returns `null` for it, there is no way to look it up afterwards. To give an
existing user a new initial password (again with a forced change at the first
login), replace it:
`terraform apply -replace='module.zitadel_portal.zitadel_human_user.user["<name>"]'`
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

[`apps.tf`](./apps.tf) adds OIDC clients next to the portal, from
[`apps.auto.tfvars`](./apps.auto.tfvars) -- per app:

- **project** `<app>` with role check (no role on it, no login) and role
  assertion; its **roles**, keys prefixed with the app name (`argocd-admin`)
- **OIDC web app** `<app>`: redirect/post-logout paths on its base URL, code
  flow, basic auth, roles and profile claims in the ID token
- **grants** for users of `users.auto.tfvars` (ids from the module output
  `user_ids`)

[`groups-claim.tf`](./groups-claim.tf): an Actions-v1 script on the
customise-token flow (userinfo + access token) sets a flat **`groups`** claim
with every role key the user holds on any project. ArgoCD, Grafana, MinIO and
OpenBao read that; each matches only its own keys. Actions v1 is deprecated in
ZITADEL v4 -- check it before a major upgrade.

**Every app keeps its local admin** -- these clients add a login, they replace
none (harvester#574).

```bash
terraform output -json app_client_ids     | jq -r '.argocd'
terraform output -json app_client_secrets | jq -r '.argocd'   # sensitive -- don't paste
```

| App | URL | Roles | Local fallback |
|---|---|---|---|
| `argocd` | `https://argocd.platform.sthings.lab` | `argocd-admin`, `argocd-readonly` | `admin` |
| `minio` | `https://artifacts-console.platform.sthings.lab` | `minio-admin`, `minio-readonly` (MinIO policies of the same name) | root user |

### Wiring ArgoCD

`../apps/argocd-platform.yaml` patches the HelmRelease `argocd-deployment`:
`url`, RBAC (`argocd-admin` => `role:admin`, `argocd-readonly` =>
`role:readonly`, scopes `[groups]`) and `oidc.config` via `valuesFrom` from the
SOPS Secret `argocd-oidc-zitadel` in `argocd` (`../apps/argocd-oidc-zitadel.enc.yaml`),
key `values.yaml`: a values document with `configs.cm."oidc.config"` (no
`targetPath` -- that parses as `--set` and breaks on commas).
It holds the client secret literally -- a `$secret:key` reference would not
survive the two Flux substitutions. Make it after an apply that changed the
argocd client:

```bash
umask 077
CID=$(terraform output -json app_client_ids | jq -r '.argocd')
terraform output -json app_client_secrets | jq -j '.argocd' > /dev/shm/argocd-cs
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
terraform apply -replace='module.zitadel_portal.zitadel_application_oidc.portal["homerun2-dev"]'
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
(this Terraform state, gzip as the backend stores it) to the bucket
`platform-zitadel-backup` on platform's MinIO, and removes what is older than
14 days. The bucket and its user come from
[`clusters/machinery-hv/xrs/platform-zitadel-backup.yaml`](../../machinery-hv/xrs/platform-zitadel-backup.yaml).

**The masterkey is not in it.** It is `ZITADEL_MASTERKEY` in
`../apps/zitadel-secrets.enc.yaml` (git, SOPS) and must be the same on the
instance a dump is restored into -- without it the encrypted data in the dump
(keys, secrets) is lost.

Same VM as ZITADEL: this covers a deleted namespace, a broken database and a
bad upgrade, not the loss of the platform VM.

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
kubectl -n zitadel logs job/zitadel-backup-manual -c upload    # mc ls of the bucket
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

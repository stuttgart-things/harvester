# OpenBao setup for `tabletennis`

Two jobs in one apply, because they share a `cluster_name` and a kubeconfig:

1. **Kubernetes auth for cert-manager** — the clusterbook half that cannot be
   created from `clusters/platform/openbao`, because it is configured with *this*
   cluster's API address, CA and reviewer JWT.
2. **The application secrets** — the KV mount, its three entries, the read policy,
   and the ESO auth mount that lets External Secrets reach them.

The PKI is **not** here: it lives on `platform` and is created exactly once, by
`clusters/platform/openbao`. Recreating it here would fork the CA. The
`vault-pki` ClusterIssuer is not here either — it comes from the Argo CD
`cert-manager-vault-pki-clusterbook` ApplicationSet, driven by annotations on the
`RancherCluster` XR.

**Order, prerequisites, the CA question, how to get a kubeconfig for this cluster,
and how to verify are in [`../../OPENBAO-CLUSTERBOOK.md`](../../OPENBAO-CLUSTERBOOK.md).**
Read it first; two of the steps fail silently out of order.

| | |
|---|---|
| Auth mount, cert-manager | `/v1/auth/tabletennis-sthings-certmanager` |
| Auth mount, External Secrets | `/v1/auth/tabletennis-sthings-eso` |
| KV v2 mount | `tabletennis` |
| Policy | `read-tabletennis` |
| Terraform state | `kubernetes` backend, Secret suffix `openbao-tabletennis-sthings`, ns `cert-manager`, in this cluster |

## The three entries, and who reads each property

One entry per application. All three sit in the `tabletennis` mount, and every
name below is fixed by something outside this directory — none of them is a free
choice.

| Entry | Property | Read by | Fixed by |
|---|---|---|---|
| `homerun2` | `authToken` | omni-pitcher (`/pitch` bearer), scout | the XR annotation `homerun2-platform…/secret-key` |
| | `redisPassword` | redis-stack, omni-pitcher, core-catcher, scout, led-catcher | |
| `schmetterpause` | `session-key`, `username`, `password` | the app and its CloudNativePG database | hard-coded in `schmetterpause-kustomize` |
| `zaehlwerk` | `omni-pitcher-token` | zaehlwerk's scoreboard panel | hard-coded in `zaehlwerk-kustomize` |
| | `redis-password` | zaehlwerk | |

> [!IMPORTANT]
> **`zaehlwerk:omni-pitcher-token` must equal `homerun2:authToken`, byte for byte.**
> They are the two ends of one bearer token. Get it wrong and `/pitch` answers
> 401 — the Pods stay Healthy, the scoreboard just never updates, and the only
> trace is a `panel pitch failed, point not shown` line in zaehlwerk's log.
> `zaehlwerk:redis-password` must likewise equal `homerun2:redisPassword`: it is
> the same Redis.

**Why `homerun2` and not `tabletennis`.** The homerun2 bundle names its entry
after the cluster by default. schmetterpause and zaehlwerk cannot — their entry
names are baked into their published kustomize bases, and the catalog charts patch
only the store, not the key. So the XR sets
`homerun2-platform.stuttgart-things.com/secret-key: homerun2` and all three end up
app-named. Remove that annotation and homerun2 silently starts reading
`tabletennis/data/tabletennis`, which this Terraform does not create.

## tfvars

`terraform.tfvars.sops.json` holds the real values, encrypted. Decrypt it — never
copy `terraform.tfvars.example.json` into place, it contains only placeholders.

```bash
# generate
openssl rand -hex 32     # homerun2 authToken  (= zaehlwerk omni-pitcher-token)
openssl rand -hex 24     # homerun2 redisPassword (= zaehlwerk redis-password)
openssl rand -hex 24     # schmetterpause session-key
openssl rand -hex 24     # schmetterpause password

# encrypt
export AGE_PUBLIC_KEY="age1..."
dagger call -m github.com/stuttgart-things/dagger/sops encrypt \
  --age-key="env:AGE_PUBLIC_KEY" \
  --plaintext-file="./terraform.tfvars.json" \
  --file-extension="json" \
  export --path="./terraform.tfvars.sops.json"
rm terraform.tfvars.json          # the plaintext does not stay on disk

# decrypt, at apply time
export SOPS_AGE_KEY="AGE-SECRET-KEY-1..."
dagger call -m github.com/stuttgart-things/dagger/sops decrypt \
  --age-key="env:SOPS_AGE_KEY" \
  --encrypted-file="./terraform.tfvars.sops.json" contents > terraform.tfvars.json
```

`secret_engines` is declared `sensitive = true`, so the values do not appear in
plan or apply output. They **are** in the state — which is why the backend is a
Secret in the cluster rather than a file.

## Apply

```bash
export VAULT_ADDR=https://openbao.platform.sthings.lab
export VAULT_TOKEN=<a token that may write auth mounts and KV on that OpenBao>

KUBECONFIG_PATH=/home/sthings/.kube/tabletennis \
  ../../platform/openbao/preflight.sh \
  && terraform init \
  && terraform apply -var-file=terraform.tfvars.json
```

The cluster has to be up first: the auth mounts are configured with its API
address, CA and reviewer JWT. Until this runs, its `vault-pki` ClusterIssuer sits
not-Ready — that is the intended signal, not a fault.

If `preflight.sh` reports `vault-auth-reviewer` already exists (blueprints
`CreateVaultKubernetesAuth` ran against this cluster), add
`k8s_auth_reviewer_create = false` to the module block. That argument exists only
on the pinned commit, not in v1.2.0 — see the note on the `source` line for why
this is pinned to a commit rather than to that tag.

## Then: the ClusterSecretStore

Terraform makes the secrets reachable; this is what reaches for them. From
`infra/external-secrets/cluster-secret-store-vault` in `stuttgart-things/argocd`:

```yaml
name: vault-tabletennis
server: https://openbao.platform.sthings.lab
path: tabletennis
version: v2
auth:
  kubernetes:
    mountPath: tabletennis-sthings-eso
    role: eso
    serviceAccountRef:
      name: eso
      namespace: external-secrets
```

`caProvider` stays at its default — the `vault-pki-ca` Secret in `cert-manager`,
which the network platform already puts on every Vault-aware cluster.

The ServiceAccount `eso` in `external-secrets` is created by this Terraform, as
the identity the auth mount admits. External Secrets mints a token for it, so its
controller needs `create` on `serviceaccounts/token` for that name — the default
ESO install has it.

## Last: the gates

Only once a `kubectl get clustersecretstore vault-tabletennis` reports `Valid`,
flip both labels in the XR from `'false'` to `'true'`:

```
homerun2-platform.stuttgart-things.com/secrets-config
tabletennis-platform.stuttgart-things.com/secrets-config
```

Before that they hold the two app platforms back on purpose. ExternalSecrets fail
closed: labelled early, the Pods sit in `CreateContainerConfigError` waiting for
Secrets that never appear, and schmetterpause's database never bootstraps at all —
it initialises from the Secret its own ExternalSecret produces.

## Verify

```bash
# the two auth mounts
bao auth list | grep tabletennis-sthings

# the entries (values redacted by -field=keys)
bao kv get -format=json tabletennis/homerun2       | jq '.data.data | keys'
bao kv get -format=json tabletennis/schmetterpause | jq '.data.data | keys'
bao kv get -format=json tabletennis/zaehlwerk      | jq '.data.data | keys'

# the two ends of the bearer token agree
diff <(bao kv get -field=authToken tabletennis/homerun2) \
     <(bao kv get -field=omni-pitcher-token tabletennis/zaehlwerk) && echo "token matches"

# after the gates: every ExternalSecret synced
kubectl get externalsecret -A
```

# Application secrets for workload clusters

The KV mount, its entries and the read policy that **External Secrets** on a
workload cluster reads through. They live here, under `platform`, rather than
beside the cluster they serve.

## Why here

OpenBao runs on `platform`. These objects are objects *on it* — a mount, some
KV entries, a policy — and none of them needs the workload cluster to exist.

The workload cluster is the shorter-lived thing. `tabletennis` may be torn down
and rebuilt; when it is, its credentials should still be here rather than having
to be regenerated, re-encrypted and redistributed. A rebuild then costs one
`terraform apply` in that cluster's own `openbao/` directory — the Kubernetes
auth mounts, which genuinely die with it, because each is configured with that
cluster's API address, CA and reviewer JWT.

That is the whole split:

| | |
|---|---|
| **here** | mount, entries, policy — outlive the cluster, need it for nothing |
| `clusters/<cluster>/openbao/` | the Kubernetes auth mounts — configured *with* the cluster, die with it |

## Order, and half of it fails silently

```
1. this directory                  the mount, the entries, the policy
2. clusters/<cluster>/openbao      the auth mounts, one role bound to that policy
```

**A role bound to a policy that does not exist logs in successfully and is
granted nothing.** Run it the other way round and nothing errors — the symptom is
an ExternalSecret that never syncs, noticed hours later. This apply needs no
cluster, so there is no reason not to run it first.

## What is in it today

One mount per workload cluster. `tabletennis` holds three entries, one per
application:

| Entry | Property | Read by |
|---|---|---|
| `tabletennis/homerun2` | `authToken` | omni-pitcher (`/pitch` bearer), scout |
| | `redisPassword` | redis-stack, omni-pitcher, core-catcher, scout, led-catcher |
| `tabletennis/schmetterpause` | `session-key`, `username`, `password` | the app and its CloudNativePG database |
| `tabletennis/zaehlwerk` | `omni-pitcher-token` | zaehlwerk's scoreboard panel |
| | `redis-password` | zaehlwerk |

Policy `read-tabletennis` grants `read` on all three. The `eso` role in
`clusters/tabletennis/openbao` names it.

> [!IMPORTANT]
> **Two pairs must match byte for byte.** `zaehlwerk:omni-pitcher-token` =
> `homerun2:authToken` — they are the two ends of one bearer token, and getting
> it wrong makes `/pitch` answer 401 with no symptom beyond a
> `panel pitch failed, point not shown` line in zaehlwerk's log.
> `zaehlwerk:redis-password` = `homerun2:redisPassword`, because it is the same
> Redis.

**None of the entry names is a free choice.** `schmetterpause` and `zaehlwerk`
are hard-coded in those apps' published kustomize bases — the catalog charts patch
the store onto their ExternalSecrets, not the key. `homerun2` is set by the XR
annotation `homerun2-platform.stuttgart-things.com/secret-key`; without it that
bundle reads an entry named after the *cluster* instead.

Adding another cluster means appending entries with a new `path`, and a second
policy. The module makes one mount per distinct `path` and one entry per
`path` + `name`.

## tfvars

`terraform.tfvars.sops.json` holds the real values, encrypted. Decrypt it — never
copy `terraform.tfvars.example.json` into place, it holds only placeholders.

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

The values stay out of plan and apply output — but NOT because `secret_engines`
is marked sensitive. It is not, and cannot be: the module keys its `for_each` on
mount paths derived from this variable, and terraform refuses a sensitive value
there (`Invalid for_each argument`). The vault provider marks `data_json`
sensitive by itself, which is what actually masks them; measured on real input,
the generated token appears zero times in plan output against six
`(sensitive value)` maskings. See the comment on the variable.

They **are** in the state either way — which is why the backend is a Secret in
the cluster rather than a file.

## Apply

```bash
export VAULT_ADDR=https://openbao.platform.sthings.lab
export VAULT_TOKEN=<a token that may write KV and policies on that OpenBao>

terraform init && terraform apply -var-file=terraform.tfvars.json
```

No workload cluster required. The platform kubeconfig in `kubeconfig_path` is
only there because the module's provider configuration demands one — `k8s_auths`
is empty, so this root creates nothing in Kubernetes.

## Verify

```bash
bao secrets list | grep tabletennis
bao policy read read-tabletennis

bao kv get -format=json tabletennis/homerun2       | jq '.data.data | keys'
bao kv get -format=json tabletennis/schmetterpause | jq '.data.data | keys'
bao kv get -format=json tabletennis/zaehlwerk      | jq '.data.data | keys'

# the two ends of the bearer token agree
diff <(bao kv get -field=authToken tabletennis/homerun2) \
     <(bao kv get -field=omni-pitcher-token tabletennis/zaehlwerk) && echo "token matches"
```

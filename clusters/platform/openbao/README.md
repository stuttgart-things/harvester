# OpenBao on `platform` — the manual steps

The instance that **replaces** the Vault on the `infra` cluster, which is being
switched off to free the hardware.

## Why this exists

The `vault-pki` ClusterIssuer on the harvester clusters authenticates to Vault
with a token that `vault-base-setup` creates at its default TTL of **720h** and
that nothing renews. The chain that follows is the reason certificates here
expire every three months:

| Day | What happens |
|---|---|
| 0 | Certificate issued for 90 days (`duration: 2160h`) |
| 30 | The Vault token dies. The ClusterIssuer keeps reporting `Ready` — cert-manager verifies only the Vault **login**, never the ability to sign |
| 75 | cert-manager attempts renewal (`renewBefore: 360h`). It fails, silently |
| 90 | The certificate expires. Somebody notices |

Kubernetes auth removes the credential instead of lengthening it: cert-manager
mints a ServiceAccount token per signing request through the TokenRequest API,
and nothing long-lived is stored in the cluster at all.

## What runs where

| Step | Who |
|---|---|
| namespace, HelmRepository, HelmRelease, HTTPRoute | Flux — `../apps-platform.yaml`, component `../components/openbao` |
| the static seal Secret | Flux — `../apps/openbao-static-seal.enc.yaml`, SOPS |
| **`bao operator init`** | **a human, once** — step 2 |
| PKI mount, root CA, role, policy, Kubernetes auth backend | Terraform — this directory, step 3 |
| the ClusterIssuer | Flux — component `cert-manager-vault-issuer`, step 5 |

Not a matter of taste: Terraform needs a token that only `init` produces, and
Flux has no OpenBao credentials.

> Rehearsed end-to-end on `cicd-test3` first — see
> `stuttgart-things/clusters/labda/vsphere/cicd-test3/OPENBAO.md`.

---

## 1. Let Flux deploy it — and expect the first run to time out

```bash
export KUBECONFIG=~/.kube/platform.sthings.lab
flux reconcile kustomization apps-platform --with-source
kubectl -n openbao get pods -w
```

**`apps-platform` will report a timeout here. That is correct, not a fault.**
The chart's readiness probe is:

```
exec: ["/bin/sh", "-ec", "bao status -tls-skip-verify"]   # exit 0 only when unsealed
```

A fresh instance is `Initialized=false, Sealed=true` → exit 2 → the pod never
becomes Ready → a `wait: true` Kustomization cannot succeed on first install.
The static seal unseals on every **restart**; it does not **initialise**.

```bash
kubectl -n openbao exec openbao-0 -- bao status   # Initialized false, Sealed true
```

## 2. Initialise — once, by hand

```bash
kubectl -n openbao exec -it openbao-0 -- bao operator init \
  -recovery-shares=1 -recovery-threshold=1
```

With an auto-seal active this returns **recovery keys**, not unseal keys. Nobody
needs them to reboot the pod; they exist for an emergency where the seal key
itself is gone.

> ### The recovery key does NOT replace the root token
>
> An earlier version of this file said the recovery keys "exist only to
> regenerate a root token". **That is wrong on an auto-unsealed instance, and
> acting on it cost this cluster its root token.** Verified on OpenBao 2.6.2,
> 2026-09-07, in normal mode:
>
> | call | answer |
> |---|---|
> | `bao operator generate-root -init` | `403` — the CLI targets `sys/generate-root-token/attempt`, which does not exist |
> | `PUT sys/generate-root/attempt` | `unsupported operation` — the route is there, the operation is not |
> | `bao operator generate-root -init -recovery-token` | `403` — `sys/generate-recovery-token/attempt` is closed outside recovery mode |
>
> The ceremony exists **only in recovery mode** (`bao server … -recovery`), and
> the token it yields authenticates against `sys/raw` alone — raw storage, not
> an administrative API. It cannot create auth mounts, policies or tokens.
>
> **So the root token is the only administrative credential this instance has,
> and it has exactly one copy.** Treat losing it as losing the instance.

Store the output somewhere that survives this machine, and in **two** places,
because there is no ceremony to fall back on.

**Recorded, 2026-09-08.** This line was in the file from the start and was never
filled in; when the token was needed on 2026-09-07 nobody knew where to look,
and the answer turned out to be "nowhere". It now reads:

```
root token:   clusters/platform/openbao/init.enc.yaml   key: root_token
recovery key: clusters/platform/openbao/init.enc.yaml   key: recovery_keys_b64
```

SOPS/age, same recipient as every other `*.enc.yaml` here. Read it with

```bash
sops --decrypt clusters/platform/openbao/init.enc.yaml
```

It is **not** a Kubernetes manifest and nothing applies it. It lives in this
Terraform directory precisely because no Flux Kustomization recurses here — a
Secret-shaped file under `../apps/` would have been picked up and rolled out.

**This is a compromise, and worth naming as such.** The paragraph above used to
say "a KV path on another instance, never on disk", which is the better answer;
it was not taken because there is no second instance to hold it — the Vault on
`infra` is being switched off, which is why this OpenBao exists at all. So:

- The token is on disk, encrypted. Whoever holds the age key holds the token.
  That key is currently in the environment as `SOPS_AGE_KEY`, so the blast
  radius is "anyone with this shell", not "anyone with the repo".
- It is in git, so it is backed up and versioned — which is the half of "two
  places" this buys. **The second place is still missing.**
- When a second OpenBao exists, move it to a KV path there and cut this file
  back to a pointer.

> There is also still a **plaintext** copy in `~/openbao-ca-bundle/init.json`
> (root token *and* recovery keys, mode 0600), left from the 2026-09-07 rescue,
> alongside `ca.key` — the rescued CA private key, also plaintext. Deliberately
> not deleted yet. Both should be `shred -u`'d once the CA is confirmed to need
> no further hand-work; until then this note is the record that they exist.

> **Why this is not automated.** The obvious candidate is the `vault-autounseal`
> operator. It does not help: with a static seal there is nothing to unseal, and
> the only part it would add — running `init` — it does by writing the root
> token and the recovery keys into a Secret in this namespace, permanently. That
> is a strictly worse version of the trade-off already accepted here; it is
> unlicensed and unmaintained since 2025-06-10; and it is a *Vault* operator
> never tested against an OpenBao auto-seal init response. Init is a one-time
> trust-establishing event. Automating it means something holds a root token
> forever — which is the defect this whole migration exists to remove.

Then let the Kustomization recover:

```bash
flux reconcile kustomization apps-platform
kubectl -n openbao exec openbao-0 -- bao status   # Initialized true, Sealed false
```

## 3. PKI and Kubernetes auth — Terraform

```bash
export VAULT_ADDR=https://openbao.platform.sthings.lab
export VAULT_TOKEN=$(sops --decrypt init.enc.yaml \
  | python3 -c 'import yaml,sys; print(yaml.safe_load(sys.stdin)["root_token"])')

./preflight.sh && terraform init && terraform apply
```

**Run `preflight.sh`, do not skip to `apply`.** It compares this directory
against the *live* cluster — the reviewer question below, whether OpenBao is
initialised and unsealed, and whether the token still works. A note in a runbook
is read once and a value answered once lands in `terraform.tfvars` and is wrong
the next time the cluster is rebuilt; this fails on the mismatch itself, every
time. It is also how the `cicd-test3` rehearsal would have avoided its one
failed apply.

Creates the PKI mount and **its own root CA** (`CN=sthings.lab`, RSA-4096, 10
years), the `sthings-lab` signing role, the `pki-issue` policy, and the
Kubernetes auth backend at `/v1/auth/platform-sthings-certmanager`.

**Requires vault-base-setup#54.** Without it `k8s.tf` binds
`system:auth-delegator` — the right to review any token in the cluster — to the
*same* ServiceAccount that logs in. Trading a long-lived token for an
over-broad permission is not the improvement this migration is for.

`preflight.sh` checks this for you and refuses to continue on a mismatch — in
either direction, including a stale `k8s_auth_reviewer_create = false` left in
the file for a cluster that no longer has the reviewer. By hand it is:

```bash
kubectl -n kube-system get sa vault-auth-reviewer
```

If it exists, add `k8s_auth_reviewer_create = false` to `openbao.tf`. The VM
pipeline's `CreateVaultKubernetesAuth` creates the ServiceAccount, its SA-token
Secret and the ClusterRoleBinding under exactly the names the module wants, and
two owners for one identity is not a conflict Terraform resolves — it stops with
`serviceaccounts "vault-auth-reviewer" already exists`. This is how the
rehearsal on `cicd-test3` failed. This cluster is built by Ansible rather than
that pipeline, so it should not be there, but check rather than assume.

Two things that were suspect and turned out fine, verified on OpenBao **2.6.2**
during the rehearsal: `disable_iss_validation = true` is accepted, and the
`hashicorp/vault` provider drives OpenBao's PKI and Kubernetes auth with no
OpenBao-specific handling at all.

Export the CA — it is the input to all the trust-store work:

```bash
terraform output -raw pki_ca_cert > sthings-lab-ca.crt
openssl x509 -in sthings-lab-ca.crt -noout -subject -dates
```

## 4. Revoke the root token — only once a replacement path exists

```bash
bao token revoke <root token>
```

Skipping this recreates on OpenBao exactly the problem being left behind on
`infra`. From here nothing in the cluster holds a long-lived credential.

> **Do not run this until the stored copies from step 2 are verified and a
> second administrative path exists.** Revoking is what made the cluster
> unadministrable on 2026-09-07: the token was revoked here, the only stored
> copy was then deleted from Git by #167 on the assumption that the recovery
> ceremony could mint another, and it cannot (see step 2).
>
> A defensible sequence: revoke this token, and in the same session create a
> narrowly-scoped admin token or auth role that can write `sys/auth/*` — so that
> "no long-lived credential" does not also mean "no way back in".

## 5. Point cert-manager at it — nothing to do

Already in Git: the `cert-manager-openbao-issuer` Kustomization in
`../infra.yaml`. It sits **not-Ready until step 3 has run**, because the auth
mount and the PKI it names come from Terraform — which is correct, and loud.

> **It does NOT go green on its own — nudge it.** A ClusterIssuer that failed
> once keeps the failure on its status and does not retry on any useful cadence.
> On apps1, 2026-09-07, the condition still read
>
>     Failed to initialize Vault client: ... serviceaccounts "certmanager" not found
>
> nearly three hours after Terraform had created that ServiceAccount — the
> condition's lastTransitionTime was 12:37, the SA's creationTimestamp 15:28.
> Certificates queue behind it with `Referenced issuer does not have a Ready
> status condition`, which points at the issuer and says nothing about why.
>
> Any write to the object triggers a reconcile:
>
> ```bash
> kubectl annotate clusterissuer <name> reconcile=$(date +%s) --overwrite
> ```
>
> It went `Ready=True VaultVerified` within seconds. Check the condition's age
> against the thing it complains about before believing it.

The existing `vault-pki` issuer stays alive beside it. The two are independent
and coexist deliberately: every Certificate keeps its current issuer until it is
moved by hand, so nothing reissues onto a CA that nothing trusts yet.

`VAULT_ISSUER_AUTH_MOUNT_PATH`, `_AUTH_ROLE` and `_SERVICE_ACCOUNT` there must
match `k8s_auths` in `openbao.tf` exactly — the module derives the mount from
`<cluster_name>-<name>` and binds the role to a ServiceAccount of that same
`name`. Change one and all three move.

> **The in-cluster HTTP address is deliberate.** Going through the Gateway
> (`https://openbao.platform.sthings.lab`) is circular: that hostname's
> certificate is issued by this very issuer. In-cluster there is no certificate
> to verify and no chicken-and-egg. That is what `components: [./components/ca-none]`
> is for — stuttgart-things/flux#356, in `v1.51.0`; this cluster tracks `main`,
> so it is already there.

The component also ships the `cert-manager-tokenrequest` Role, which the
cert-manager chart stopped rendering in v1.21. Without it cert-manager cannot
mint the ServiceAccount token — and the ClusterIssuer still reports `Ready`,
so certificates simply never appear. **Do not drop it.** That failure was
reproduced deliberately on `cicd-test3`: issuer `Ready=True/VaultVerified`,
Certificate `Ready=False` forever, and the only signal anywhere is the
cert-manager log.

## 6. Verify — all four, none assumed

```bash
# a) a certificate is issued by the new issuer at all
kubectl apply -f - <<'EOF'
apiVersion: cert-manager.io/v1
kind: Certificate
metadata: {name: openbao-probe, namespace: default}
spec:
  secretName: openbao-probe-tls
  commonName: probe.platform.sthings.lab
  dnsNames: [probe.platform.sthings.lab]
  issuerRef: {name: openbao-pki, kind: ClusterIssuer}
  duration: 2160h
  renewBefore: 360h
EOF
kubectl get certificate openbao-probe -w

# b) the chain comes from the NEW root, not the old infra one
kubectl get secret openbao-probe-tls -o jsonpath='{.data.tls\.crt}' \
  | base64 -d | openssl x509 -noout -subject -issuer -dates

# c) the seal survives a restart with nobody typing anything
kubectl -n openbao delete pod openbao-0
kubectl -n openbao exec openbao-0 -- bao status        # Sealed false

# d) renewal works with no token anywhere — the actual point
kubectl delete secret openbao-probe-tls
kubectl get certificate openbao-probe -w               # READY=True again
```

(c) is worth re-running after any change to the seal Secret: a broken seal does
not surface until the next restart, which may be weeks later. (d) is what fails
on `infra` today, 30 days after each Terraform run, silently.

---

## Still open after this

**The new root CA is trusted by nothing until it is distributed.** Ansible for
VMs, Flux/Argo for clusters, across the whole harvester environment. Until that
lands, certificates signed here are valid and rejected everywhere. It is
separate work and it is the larger half of the migration.

Only then does the `infra` Vault come down.

---

## Breaking glass: recovering the CA when the root token is gone

Done for real on 2026-09-07. Recovery mode cannot give you back an
administrative token — but it can give you back the **CA private key**, which is
the part that would otherwise cost a full re-distribution across the estate.

With the key in hand, re-initialising OpenBao stops being a catastrophe: the
PKI mount, auth backend, policy and role all come from Terraform, and the CA is
re-imported rather than regenerated. Nothing downstream notices.

**You need the `UNSEAL` recovery key from step 2.** Without it, stop here.

```bash
# 1. into recovery mode. Flux owns the StatefulSet, so suspend it first,
#    and SAVE THE ORIGINAL ARGS — you are editing a live workload.
kubectl -n flux-system patch kustomization openbao --type=merge -p '{"spec":{"suspend":true}}'
kubectl -n openbao      patch helmrelease  openbao --type=merge -p '{"spec":{"suspend":true}}'
kubectl -n openbao get sts openbao \
  -o jsonpath='{.spec.template.spec.containers[0].args[0]}' > /tmp/args.orig
# append ' -recovery' to the `bao server -config=...` invocation in those args,
# patch the sts, delete the pod, then confirm:
kubectl -n openbao logs openbao-0 | grep 'Recovery Mode'      # must say true

# 2. mint a recovery token. -recovery-token on EVERY call.
kubectl -n openbao exec -it openbao-0 -- bao operator generate-root -recovery-token -generate-otp
kubectl -n openbao exec -it openbao-0 -- bao operator generate-root -recovery-token -init -otp=<OTP>
kubectl -n openbao exec -i  openbao-0 -- bao operator generate-root -recovery-token -nonce=<NONCE> - < unseal.key
# DECODE LOCALLY — `-decode` first GETs the attempt status, which 500s once the
# ceremony has completed ("...when already unsealed"):
python3 -c "import base64,sys; e,o=sys.argv[1:3]; \
  print(''.join(chr(b^ord(o[i])) for i,b in enumerate(base64.urlsafe_b64decode(e+'='*(-len(e)%4)))))" <ENCODED> <OTP>

# 3. read the CA. sys/raw is served in recovery mode; sys/seal-status is not.
RT=<recovery token>
G() { kubectl -n openbao exec openbao-0 -- sh -c "wget -qO- --header='X-Vault-Token: $RT' 'http://127.0.0.1:8200/v1/$1'"; }
G 'sys/raw/logical/?list=true'                    # one dir per mount; pki is the one with role/
G "sys/raw/logical/$PKI/config/issuers"           # -> default issuer id
G "sys/raw/logical/$PKI/config/keys"              # -> default key id
G "sys/raw/logical/$PKI/config/issuer/$ISSUER"    # .certificate
G "sys/raw/logical/$PKI/config/key/$KEY"          # .private_key
```

Then verify before trusting it — fingerprint against the distributed root, and
that the key actually belongs to the certificate:

```bash
openssl x509 -in ca.crt -noout -fingerprint -sha256
diff <(openssl x509 -in ca.crt -noout -modulus) <(openssl rsa -in ca.key -noout -modulus)
```

Undo everything afterwards: restore the args from `/tmp/args.orig`, delete the
pod, un-suspend Flux. Confirm `bao status` answers normally again.

### Four things that cost an hour, so they are written down

- **`raw_storage_endpoint` is not needed.** `sys/raw` is already routed in
  recovery mode. A `404` from `sys/raw/<key>` means the KEY is absent, not the
  route — `sys/raw` itself answers `307` (the mux redirecting to its trailing
  slash). Enabling the option changed nothing, and it must not be left on in
  normal mode: it bypasses every policy.
- **The storage layout is not `config/ca_bundle`.** That is the pre-multi-issuer
  spelling. Here it is `config/issuer/<id>` and `config/key/<id>`, with
  `config/issuers` and `config/keys` naming the defaults — and note they sit
  under `config/`, not at the mount root.
- **Only one recovery token exists at a time.** Every further `-generate-otp`
  then fails with `attempted to generate recovery operation token when already
  unsealed`, which reads like a fault and is not one. Restarting the pod clears
  it; recovery tokens are not persisted.
- **`clusters/platform/secrets.yaml` does not decrypt as a whole.** Its three
  documents were encrypted separately and concatenated, and SOPS binds each
  value's AES-GCM tag to its path, so `sops -d` on the file fails with
  `cipher: message authentication failed` — which looks like a broken age key
  and is not. Split the document out first:
  ```bash
  awk 'BEGIN{d=1} /^---$/{d++} d==3' clusters/platform/secrets.yaml \
    | sed '1{/^---$/d}' > /tmp/doc3.yaml && sops -d /tmp/doc3.yaml
  ```

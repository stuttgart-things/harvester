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
needs them to reboot the pod — they exist only to regenerate a root token, or
for an emergency where the seal key itself is gone.

Store the output the way `sthings-infra` does: in a KV path on another instance,
never on disk. Record here where it went, because there will be no second copy.

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
export VAULT_TOKEN=<root token from step 2>

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

## 4. Revoke the root token

```bash
bao token revoke <root token>
```

Skipping this recreates on OpenBao exactly the problem being left behind on
`infra`. From here nothing in the cluster holds a long-lived credential.

## 5. Point cert-manager at it

A `cert-manager-vault-issuer` Kustomization in `../infra.yaml`. Keep the
existing `vault-pki` issuer alive alongside it until every Certificate has
moved — the two are independent and can coexist.

```yaml
VAULT_ISSUER_NAME: openbao-pki
VAULT_ISSUER_SERVER: http://openbao.openbao.svc.cluster.local:8200
VAULT_ISSUER_PKI_PATH: pki/sign/sthings-lab
VAULT_ISSUER_AUTH_MOUNT_PATH: /v1/auth/platform-sthings-certmanager
VAULT_ISSUER_AUTH_ROLE: certmanager
VAULT_ISSUER_SERVICE_ACCOUNT: certmanager
```

Those last three must match `k8s_auths` in `openbao.tf` exactly — the module
derives the mount from `<cluster_name>-<name>`, and binds the role to a
ServiceAccount of that same `name`.

> **The in-cluster HTTP address is deliberate.** Going through the Gateway
> (`https://openbao.platform.sthings.lab`) is circular: that hostname's
> certificate is issued by this very issuer. In-cluster there is no certificate
> to verify and no chicken-and-egg.
>
> This is the one change the Flux component needs — it renders
> `caBundleSecretRef` **unconditionally**, and there is no CA to point it at
> here. Small PR against `stuttgart-things/flux` to make it optional.

The component also ships the `cert-manager-tokenrequest` Role, which the
cert-manager chart stopped rendering in v1.21. Without it cert-manager cannot
mint the ServiceAccount token — and the ClusterIssuer still reports `Ready`,
so certificates simply never appear. Do not drop it.

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

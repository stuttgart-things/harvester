# OpenBao Kubernetes auth for `tabletennis`

Two auth mounts on the OpenBao that runs on `platform`, and nothing else. Each is
configured with **this** cluster's API address, CA and reviewer JWT, which is why
they cannot be created from `clusters/platform/openbao` and why they die with the
cluster.

| Mount | Role / ServiceAccount | For |
|---|---|---|
| `/v1/auth/tabletennis-sthings-certmanager` | `certmanager` in `cert-manager` | signing certificates against the PKI on platform |
| `/v1/auth/tabletennis-sthings-eso` | `eso` in `external-secrets` | External Secrets reading the application secrets |

Mount paths come out as `<cluster_name>-<name>`. Both names are load-bearing
elsewhere: `certmanager` must match the XR annotations `vault-k8s-auth-mount` /
`-role` / `-sa` exactly, and `eso` must match the ClusterSecretStore's
`auth.kubernetes.mountPath`, whose convention is `<cluster-name>-eso`.

## What is deliberately not here

**The secrets.** The KV mount, its entries and the `read-tabletennis` policy live
in [`../../platform/openbao/app-secrets`](../../platform/openbao/app-secrets/),
because they are objects on the OpenBao rather than on this cluster — so they
survive a teardown and rebuild of tabletennis, and a rebuild costs only this
apply.

**The PKI.** It lives on `platform` and is created exactly once, by
`clusters/platform/openbao`. Recreating it here would fork the CA.

**The ClusterIssuer.** It comes from the Argo CD ApplicationSet
`cert-manager-vault-pki-clusterbook`, driven by annotations on the
`RancherCluster` XR.

**Order, prerequisites, the CA question, how to get a kubeconfig for this cluster,
and how to verify are in [`../../OPENBAO-CLUSTERBOOK.md`](../../OPENBAO-CLUSTERBOOK.md).**
Read it first; several of the steps fail silently out of order.

## This directory is a candidate to disappear

[crossplane-configurations#411](https://github.com/stuttgart-things/crossplane-configurations/issues/411)
is the work that would replace it. The `rancher-cluster` Composition grew
`spec.vaultAuth.composeMount`, which composes a `VaultK8sAuth` creating the
cert-manager mount and **deriving** the four `vault-k8s-auth-*` annotations, so
they can no longer drift from the mount. Strictly better than doing it here.

Not used yet, for two reasons:

1. **It is not on the control plane.** ghcr and `crossplane-mgmt` both carry
   `rancher-cluster` **v0.7.1**; the repo is at v0.7.2. v0.7.1 predates #392
   Phase 1 and Phase 2, so `vaultAuth` does not exist there at all — not even
   `enabled`. That is blocker 1 of #411, and the composed chain has never been
   run against a real cluster.
2. **It would only cover half of this file.** The composed block emits exactly
   one `k8sAuths` entry — `roleName`, default `certmanager`, bound to the
   cert-manager ServiceAccount. **ESO needs a second mount**, and `composeMount`
   has no way to add one. A standalone `VaultK8sAuth` XR could, since its
   `k8sAuths[]` is a list and `vault-auth` v0.3.2 is installed — but it reads the
   reviewer Secret and `kubernetesHost` that only `vaultAuth.enabled` produces,
   so it waits on the same upgrade.

The KV half is unaffected either way: no XR creates secret engines, which is why
[`../../platform/openbao/app-secrets`](../../platform/openbao/app-secrets/) stays
Terraform regardless.

## Order, and both failures are silent

Two applies must have run before this one:

```
clusters/platform/openbao               creates the policy `pki-issue`
clusters/platform/openbao/app-secrets   creates the policy `read-tabletennis`
```

Each of the two roles here is bound to one of those. **A role bound to a policy
that does not exist logs in successfully and is granted nothing** — so running
these out of order produces no error at all. The symptom is a denied signing
request, or an ExternalSecret that never syncs, noticed much later.

Neither of those two applies needs this cluster, so run both first.

## Apply

```bash
export VAULT_ADDR=https://openbao.platform.sthings.lab
export VAULT_TOKEN=<a token that may write auth mounts on that OpenBao>

KUBECONFIG_PATH=/home/sthings/.kube/tabletennis \
  ../../platform/openbao/preflight.sh \
  && terraform init \
  && terraform apply
```

No tfvars: this root takes no secrets.

The cluster has to be up first. Until this runs, its `vault-pki` ClusterIssuer
sits not-Ready — that is the intended signal, not a fault.

If `preflight.sh` reports `vault-auth-reviewer` already exists (blueprints
`CreateVaultKubernetesAuth` ran against this cluster), add
`k8s_auth_reviewer_create = false` to the module block. That argument exists only
on the pinned commit, not in v1.2.0 — see the note on the `source` line for why
this is pinned to a commit rather than to that tag.

| | |
|---|---|
| Terraform state | `kubernetes` backend, Secret suffix `openbao-tabletennis-sthings`, ns `cert-manager`, in this cluster |

## Then: the ClusterSecretStore

This makes the secrets *reachable*; the store is what reaches. From
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

## Last: the tabletennis gate

Only once `kubectl get clustersecretstore vault-tabletennis` reports **Valid**,
flip one label in the XR from `'false'` to `'true'`:

```
tabletennis-platform.stuttgart-things.com/secrets-config
```

The homerun2 gate is already `'true'` and needs nothing: everything that bundle
can get wrong before the store answers retries by itself. tabletennis is held
back because schmetterpause's database *bootstraps* from the Secret its own
ExternalSecret produces, which is a once-only step rather than a retry loop. The
XR explains both in place.

## Verify

```bash
bao auth list | grep tabletennis-sthings
kubectl get clustersecretstore vault-tabletennis
kubectl get externalsecret -A          # after the gate
```

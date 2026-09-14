# The ESO OpenBao auth mount for `tabletennis`

One Kubernetes auth mount on the OpenBao that runs on `platform`, and that is all
this directory does.

| Mount | Role | Admits | Policy |
|---|---|---|---|
| `/v1/auth/tabletennis-sthings-eso` | `eso` | `external-secrets` in `external-secrets` | `read-tabletennis` |

## The cert-manager mount used to be here

It now comes from `spec.vaultAuth.composeMount` on the `RancherCluster` XR, which
also **derives** the four `vault-k8s-auth-*` annotations from the same values —
so the mount path can no longer drift from the annotation naming it. Proven end
to end on 2026-09-14
([crossplane-configurations#411](https://github.com/stuttgart-things/crossplane-configurations/issues/411)):
mount created with the real API address, ClusterIssuer `Ready` without a manual
step, a probe certificate verified against the OpenBao root and rejected against
an unrelated CA, and the teardown removing child, Workspace and mount.

Two caveats recorded there, neither in the Composition: one Argo CD sync had to be
triggered by hand after a nil-pointer in the cert-manager chart, and the teardown
wedges reproducibly on two `vpki` finalizers that have to be patched off.

### Why ESO did not move with it

1. **`composeMount` emits exactly one `k8sAuths` entry** — `roleName`, bound to
   the cert-manager ServiceAccount. There is no parameter for a second mount.
2. **A separately applied `VaultK8sAuth` would need `kubernetesHost`.** Its
   default, `https://kubernetes.default.svc:443`, is only meaningful in-cluster;
   the OpenBao on `platform` has to reach *this* cluster's API server by its real
   address. The composed child gets that for free from `apiserverIp` in the
   reviewer Secret. A static YAML file in git cannot — the address is not known
   until the cluster is provisioned, so it would have to be filled in by hand
   afterwards.

   Terraform gets it for free as well: `vault-base-setup` reads
   `kubeconfig.clusters[0].cluster.server`. **That is the whole reason this
   directory survives** — this apply needs no edited file at any point.

When `rancher-cluster` grows a list of `k8sAuths` — the right long-term fix, and
an upstream change — this directory goes away entirely.

### It binds ESO's own ServiceAccount

Not a new one. `vault-base-setup` would otherwise create a ServiceAccount named
after the mount and admit that, but nothing else would ever use it and the
ClusterSecretStore would have to name it.

`external-secrets` in `external-secrets` is what the controller already runs as:
the chart is installed with `releaseName: external-secrets` and no
`fullnameOverride` or `serviceAccount.name`
(`argocd infra/external-secrets/install`). **Not** the `-webhook` or
`-cert-controller` ServiceAccount, which the same chart also creates.

> [!IMPORTANT]
> **Verify it on the first build, before applying:**
> `kubectl -n external-secrets get sa`. A bound ServiceAccount name that does not
> exist fails the way everything else here fails — silently.

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

## Order, and the failure is silent

One apply must have run before this one:

```
clusters/platform/openbao/app-secrets   creates the policy `read-tabletennis`
```

The role here is bound to it. **A role bound to a policy that does not exist logs
in successfully and is granted nothing** — so running these out of order produces
no error at all. The symptom is an ExternalSecret that never syncs, noticed much
later.

That apply needs no cluster, so run it first. (`clusters/platform/openbao` and
its `pki-issue` policy are still a prerequisite for the cert-manager side, but
that side is composed by the XR now and no longer passes through here.)

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
      # ESO's own controller ServiceAccount, which the auth mount admits.
      # `namespace` is required here, not optional.
      name: external-secrets
      namespace: external-secrets
```

`caProvider` stays at its default — the `vault-pki-ca` Secret in `cert-manager`,
which the network platform already puts on every Vault-aware cluster.

External Secrets mints a token for the ServiceAccount in `serviceAccountRef`, so
its controller needs `create` on `serviceaccounts/token` for that name. The chart
normally ships that — without it `serviceAccountRef` would be unusable in general
— but this is the exact spot where a gap already hid once, so check it on the
first cluster rather than assuming:

```bash
kubectl auth can-i --as=system:serviceaccount:external-secrets:external-secrets \
  create serviceaccounts/token -n external-secrets
```

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

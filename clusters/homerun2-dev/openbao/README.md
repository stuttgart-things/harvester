# The cert-manager OpenBao auth mount for `homerun2-dev`

One Kubernetes auth mount on the OpenBao that runs on `platform`, and that is
all this directory does.

| Mount | Role | Admits | Policy |
|---|---|---|---|
| `/v1/auth/homerun2-dev-certmanager` | `certmanager` | `cert-manager` in `cert-manager` | `pki-issue` |

## Why this exists as Terraform

Flux cannot create it. Configuring an auth mount needs an OpenBao token and this
cluster's API address, and Flux has neither — so the `ClusterIssuer` in
`../infra-platform.yaml` has no way to bootstrap itself.

`clusters/tabletennis/openbao` notes that its cert-manager mount moved to
`spec.vaultAuth.composeMount` on the RancherCluster XR, which derives the mount
path and the annotations from one value. That is the better mechanism and it is
not available here: `homerun2-dev` has no XR, it is hand-built from
`vms/homerun2-dev.params.yaml`.

A standalone `VaultK8sAuth` XR does not substitute either. It needs
`kubernetesHost`, and the default `https://kubernetes.default.svc:443` is only
meaningful in-cluster — the OpenBao on `platform` has to reach **this** cluster's
API server by its real address. A composed child gets that free from
`apiserverIp`; a static YAML in git cannot, because the address is not known
until the cluster is provisioned. Terraform gets it free too — `vault-base-setup`
reads `clusters[0].cluster.server` out of the kubeconfig — so this apply needs no
hand-edited address. That is the whole reason this directory exists.

## What is NOT here

**The policy.** `pki-issue` is an object on the OpenBao, created by
`../../platform/openbao/pki.tf` alongside the `pki` mount and the `sthings-lab`
signing role. Every cluster's `certmanager` role binds the same one.

> A role bound to a policy that does not exist **logs in successfully and is
> granted nothing**. The `ClusterIssuer` then reports `Ready` while no
> Certificate is ever issued. Check the policy is there before blaming the mount.

**The PKI itself.** Mount `pki`, role `sthings-lab`, `allowed_domains =
["sthings.lab"]` with `allow_subdomains` — which is what covers
`*.homerun2-dev.sthings.lab`.

## Applying it

```bash
cd clusters/homerun2-dev/openbao

export VAULT_TOKEN=<a token that may write auth mounts on that OpenBao>

KUBECONFIG_PATH=/home/sthings/.kube/homerun2-dev \
  ../../platform/openbao/preflight.sh \
  && terraform init \
  && terraform apply
```

No tfvars: this root takes no secrets, and all three variables carry working
defaults (`https://openbao.platform.sthings.lab`,
`/home/sthings/.kube/homerun2-dev`, `homerun2-dev`). `VAULT_ADDR` need not be
exported — `preflight.sh` falls back to the URL-shaped default in `openbao.tf`.

`preflight.sh` compares this directory's configuration against the **live**
cluster, every time: that the cluster answers, that the reviewer
ServiceAccount's presence matches what the module expects, that OpenBao is
initialised and unsealed, and that the token can actually do the work rather
than merely existing.

If it reports `vault-auth-reviewer` already exists — `blueprints`
`CreateVaultKubernetesAuth` has run against this cluster — add
`k8s_auth_reviewer_create = false` to the module block. It was absent when this
was first applied, so the default is correct as written.

## Last applied

`2026-09-17`, `Apply complete! Resources: 8 added, 0 changed, 0 destroyed.`

Verified on the cluster rather than taken from that line:

```
serviceaccount/vault-auth-reviewer            kube-system
clusterrolebinding/kube-system-vault-auth-reviewer-auth-delegator
  -> system:auth-delegator
secret/tfstate-default-openbao-homerun2-dev   cert-manager
```

`system:auth-delegator` sitting on `vault-auth-reviewer` and **not** on
cert-manager's ServiceAccount is the point of the commit pin in `openbao.tf`:
in `v1.2.0` the ServiceAccount that logs in is also the one whose JWT OpenBao
presents to TokenReview, so the module grants it the right to review any token
in the cluster. `e5b4544` splits the two.

Terraform prints a deprecation warning for
`kubernetes_cluster_role_binding` → `_v1` from inside the module. It comes from
`vault-base-setup`, not from anything here, and there is nothing to fix at this
end.

## Adding ESO later

A second entry in `k8s_auths` — `name = "eso"`, namespace `external-secrets`,
bound to the `external-secrets` ServiceAccount, policy `read-homerun2-dev`
(which does not exist yet; it would be created in
`../../platform/openbao/app-secrets`). The homerun2 stack does not need it: it
runs `profiles/base`, whose credentials come from a SOPS-encrypted Secret in
this repo rather than from a `ClusterSecretStore`.

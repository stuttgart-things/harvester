# OpenBao Kubernetes auth for `k3s-xp`

This cluster does **not** get its own PKI. It authenticates against the OpenBao
on `platform` and signs there. Only the half that cannot be created from
`platform` lives here: an auth mount configured with *this* cluster's API
address, CA and reviewer JWT.

Its ClusterIssuer does not come from this repo either — it comes from the Argo CD
`cert-manager-vault-pki-clusterbook` ApplicationSet, driven by annotations on the
`RancherCluster` XR in `stuttgart-things/crossplane-configurations`.

**Order, prerequisites, the CA question, how to get a kubeconfig for this
cluster, and how to verify are all in
[`../../OPENBAO-CLUSTERBOOK.md`](../../OPENBAO-CLUSTERBOOK.md).** Read it before
applying; the steps are shared across all three clusterbook-managed clusters and
two of them fail silently if taken out of order.

| | |
|---|---|
| Auth mount created here | `/v1/auth/k3s-xp-sthings-certmanager` |
| Role / ServiceAccount | `certmanager` / `certmanager` in `cert-manager` |
| Must match XR annotation | `clusterbook.stuttgart-things.com/vault-k8s-auth-mount` |
| Terraform state | `kubernetes` backend, Secret suffix `openbao-k3s-xp-sthings`, namespace `cert-manager`, in this cluster |

```bash
export VAULT_ADDR=https://openbao.platform.sthings.lab
export VAULT_TOKEN=<a token that may write auth mounts on that OpenBao>

KUBECONFIG_PATH=/home/sthings/.kube/k3s-xp \
  ../../platform/openbao/preflight.sh && terraform init && terraform apply
```

Full context: [harvester#152](https://github.com/stuttgart-things/harvester/issues/152).

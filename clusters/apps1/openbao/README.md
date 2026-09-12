# OpenBao Kubernetes auth for `apps1`

This cluster does **not** get its own PKI. It authenticates against the OpenBao
on `platform` and signs there. Only the half that cannot be created from
`platform` lives here: an auth mount configured with *this* cluster's API
address, CA and reviewer JWT.

Its ClusterIssuer does not come from this repo either — it comes from the Argo CD
`cert-manager-vault-pki-clusterbook` ApplicationSet, driven by annotations on the
`RancherCluster` XR in `stuttgart-things/crossplane-configurations`.

**This cluster does not exist yet.** It is provisioned by the `apps1`
RancherCluster XR in this repo
(`clusters/crossplane-mgmt/xrs/infra/apps1`), and this apply can only
run once its API is reachable — the auth mount is configured with the cluster's
own address, CA and reviewer JWT. Until then its `vault-pki` ClusterIssuer sits
not-Ready, which is the intended signal.

**Order, prerequisites, the CA question, how to get a kubeconfig for this
cluster, and how to verify are all in
[`../../OPENBAO-CLUSTERBOOK.md`](../../OPENBAO-CLUSTERBOOK.md).** Read it before
applying; the steps are shared across every clusterbook-managed cluster and two of
them fail silently if taken out of order.

| | |
|---|---|
| Auth mount created here | `/v1/auth/apps1-sthings-certmanager` |
| Role / ServiceAccount | `certmanager` / `certmanager` in `cert-manager` |
| Must match XR annotation | `clusterbook.stuttgart-things.com/vault-k8s-auth-mount` |
| Terraform state | `kubernetes` backend, Secret suffix `openbao-apps1-sthings`, namespace `cert-manager`, in this cluster |

```bash
export VAULT_ADDR=https://openbao.platform.sthings.lab
export VAULT_TOKEN=<a token that may write auth mounts on that OpenBao>

KUBECONFIG_PATH=/home/sthings/.kube/apps1 \
  ../../platform/openbao/preflight.sh && terraform init && terraform apply
```

Full context: [harvester#152](https://github.com/stuttgart-things/harvester/issues/152).

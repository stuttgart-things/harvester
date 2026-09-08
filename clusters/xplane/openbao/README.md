# OpenBao Kubernetes auth for `xplane`

This cluster does **not** get its own PKI. It authenticates against the OpenBao
on `platform` and signs there. Only the half that cannot be created from
`platform` lives here: an auth mount has to be configured with *this* cluster's
API address, CA and reviewer JWT.

## Order

1. `clusters/platform/openbao` applied — it creates the PKI, the `sthings-lab`
   role and the `pki-issue` policy. **This directory depends on that and will
   not tell you if it is missing:** a role bound to a policy that does not exist
   logs in successfully and grants nothing, so it surfaces as a denied signing
   request later, not as an error here.
2. this directory
3. the CA Secret (below)
4. the `cert-manager-openbao-issuer` Kustomization in `../infra.yaml` goes green

## Apply

```bash
export KUBECONFIG=~/.kube/xplane
export VAULT_ADDR=https://openbao.platform.sthings.lab
export VAULT_TOKEN=<a token that may write auth mounts on that OpenBao>

TF=openbao.tf KUBECONFIG_PATH=~/.kube/xplane \
  ../../platform/openbao/preflight.sh && terraform init && terraform apply
```

The preflight is shared rather than copied; it reads the `.tf` in the current
directory. It catches the one thing that stopped the rehearsal on `cicd-test3`:

```
Error: serviceaccounts "vault-auth-reviewer" already exists
```

`blueprints CreateVaultKubernetesAuth` owns that identity on pipeline-built
clusters, under exactly the names the module wants. If it is there, add
`k8s_auth_reviewer_create = false` to `openbao.tf`.

## The CA Secret

Cross-cluster means HTTPS, which means verifying a certificate. The CA
*certificate* is not secret, so this is a plain manifest — no SOPS:

```bash
cd ../../platform/openbao
terraform output -raw pki_ca_cert > /tmp/ca.crt
kubectl create secret generic openbao-pki-ca -n cert-manager \
  --from-file=ca.crt=/tmp/ca.crt --dry-run=client -o yaml \
  > ../../xplane/openbao-pki-ca.yaml
```

Commit it. Until it exists the issuer Kustomization fails — correctly, and
loudly.

## Verify

`Ready=True` on the ClusterIssuer proves only that the Vault **login** works.
cert-manager never re-checks the ability to **sign**. Only an issued
Certificate is evidence:

```bash
kubectl apply -f - <<'YAML'
apiVersion: cert-manager.io/v1
kind: Certificate
metadata: {name: openbao-probe, namespace: default}
spec:
  secretName: openbao-probe-tls
  commonName: probe.xplane.sthings.lab
  dnsNames: [probe.xplane.sthings.lab]
  issuerRef: {name: openbao-pki, kind: ClusterIssuer}
  duration: 2160h
  renewBefore: 360h
YAML
kubectl get certificate openbao-probe -w
kubectl get secret openbao-probe-tls -o jsonpath='{.data.tls\.crt}' | base64 -d \
  | openssl x509 -noout -subject -issuer
```

Full context: harvester#152.

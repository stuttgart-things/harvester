# Vault ClusterIssuer Setup for xplane

Deploys a Vault-backed ClusterIssuer on the xplane cluster using the PKI engine from the infra Vault.

## Prerequisites

- cert-manager running on xplane cluster
- Vault PKI engine with role `sthings-lab` configured on infra Vault
- Vault token with admin/root access

## Run

```bash
cd /home/sthings/projects/harvester/clusters/xplane/vault
export KUBECONFIG=~/.kube/infra.sthings.lab
export VAULT_TOKEN=$(kubectl get secret vault-root-token -n vault -o jsonpath='{.data.root_token}' | base64 -d)
echo $VAULT_TOKEN

export KUBECONFIG=~/.kube/xplane
export VAULT_ADDR=https://vault.infra.sthings.lab
export VAULT_SKIP_VERIFY=true
terraform init
terraform plan
terraform apply
```

## CA Bundle (optional)

If the xplane nodes don't trust the Vault TLS certificate, get the CA and add it to `vault.tf`:

```bash
curl -sk https://vault.infra.sthings.lab/v1/pki/ca/pem | base64 -w0
```

Add to the module block:

```hcl
certmanager_vault_issuer_ca_bundle = "<output-from-above>"
```

## Verify

```bash
kubectl --kubeconfig=/home/sthings/.kube/xplane get clusterissuer vault-pki
```

## Test Certificate

```bash
kubectl --kubeconfig=/home/sthings/.kube/xplane apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: test-cert
  namespace: default
spec:
  secretName: test-cert-tls
  issuerRef:
    name: vault-pki
    kind: ClusterIssuer
  commonName: test.sthings.lab
  dnsNames:
    - test.sthings.lab
EOF
```

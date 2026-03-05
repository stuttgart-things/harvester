# INFRA.STHINGS.LAB

<details open>
<summary>CREATE K3S CLUSTER + UPLOAD ENCRYPTED KUBECONFIG</summary>

```bash
dagger call -m github.com/stuttgart-things/blueprints/vm@v1.67.0 \
execute-ansible-encrypt-and-commit \
--playbooks "sthings.rke.k3s_cluster" \
--hosts infra.sthings.lab \
--ssh-user=env:SSH_USER \
--ssh-password=env:SSH_PASSWORD \
--requirements=../../requirements.yaml \
--parameters "cilium_version=0.19.0 k3s_k8s_version=1.35.1 k3s_release_kind=k3s1 cluster_setup=singlenode fetched_kubeconfig_path=/tmp/k3s.yaml install_k3s=true k3s_state=present prepare_rancher_ha_nodes=true" \
--inventory-type cluster \
--age-public-key=env:AGE_PUB \
--export-paths "/tmp/k3s.yaml" \
--progress plain -vv \
--git-repository "stuttgart-things/harvester" \
--git-branch main \
--git-commit-message "Add encrypted kubeconfig for k3s cluster infra" \
--git-destination-path "secrets" \
--git-token=env:GITHUB_TOKEN \
--progress plain -vv
```

</details>

<details open>
<summary>CREATE K3S CLUSTER + UPLOAD ENCRYPTED KUBECONFIG</summary>


<details open>
<summary>DECRYPT + TEST KUBECONFIG</summary>

```bash
mv ../../secrets/k3s.yaml ../../secrets/infra.sthings.lab.yaml

dagger call -m github.com/stuttgart-things/dagger/sops@v0.82.1 decrypt \
  --age-key env:SOPS_AGE_KEY \
  --encrypted-file ../../secrets/infra.sthings.lab.yaml \
  export --path=/tmp/infra.sthings.lab
```

```bash
export KUBECONFIG=/tmp/infra.sthings.lab
kubectl get nodes
```

</details>

<details open>
<summary>FLUX INIT + CILIUM CONFIG</summary>

```bash
dagger call -m github.com/stuttgart-things/blueprints/kubernetes-deployment@v1.67.0 \
flux-bootstrap \
--kube-config file:///tmp/infra.sthings.lab \
--deploy-operator=true \
--commit-to-git=true \
--repository stuttgart-things/harvester \
--destination-path "clusters/infra" \
--git-username env:GITHUB_USER \
--git-password env:GITHUB_TOKEN \
--git-token env:GITHUB_TOKEN \
--sops-age-key env:SOPS_AGE_KEY \
--age-public-key env:AGE_PUB \
--render-secrets=true \
--apply-secrets=true \
--apply-config=true \
--encrypt-secrets=true \
--helmfile-ref "git::https://github.com/stuttgart-things/helm.git@cicd/flux-operator.yaml.gotmpl" \
--operator-version "0.42.1" \
--wait-for-reconciliation=true \
--progress plain
```

</details>


192.168.10.150
address=/infra.sthings.lab/192.168.10.150

nslookup anything.infra.sthings.lab 192.168.10.1

<details open>
<summary>CILIUM CONFIG+CERT-MANAGER+DNS</summary>

```bash
# APPLY GIT REPOS
cat <<EOF | kubectl apply -f -
---
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: flux-infra
  namespace: flux-system
spec:
  interval: 1m0s
  ref:
    branch: main
  url: https://github.com/stuttgart-things/flux.git
---
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: flux-apps
  namespace: flux-system
spec:
  interval: 1m0s
  ref:
    branch: main
  url: https://github.com/stuttgart-things/flux.git
EOF
```

```bash
# APPLY INFRA
cat <<EOF | kubectl apply -f -
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: cilium-lb
  namespace: flux-system
spec:
  interval: 1h
  retryInterval: 1m
  timeout: 5m
  sourceRef:
    kind: GitRepository
    name: flux-infra
  path: ./infra/cilium/components/lb
  prune: true
  wait: true
  postBuild:
    substitute:
      CILIUM_LB_IP_START: "192.168.10.150"
      CILIUM_LB_IP_STOP: "192.168.10.150"
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: cert-manager
  namespace: flux-system
spec:
  interval: 1h
  retryInterval: 1m
  timeout: 5m
  sourceRef:
    kind: GitRepository
    name: flux-infra
  path: ./infra/cert-manager/components/install
  prune: true
  wait: true
  postBuild:
    substitute:
      CERT_MANAGER_NAMESPACE: cert-manager
      CERT_MANAGER_VERSION: v1.19.1
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: cert-manager-selfsigned
  namespace: flux-system
spec:
  interval: 1h
  retryInterval: 1m
  timeout: 5m
  dependsOn:
    - name: cert-manager
  sourceRef:
    kind: GitRepository
    name: flux-infra
  path: ./infra/cert-manager/components/selfsigned
  prune: true
  wait: true
  postBuild:
    substitute:
      CERT_MANAGER_NAMESPACE: cert-manager
      CERT_MANAGER_SELFSIGNED_DOMAIN: "infra.sthings.lab"
      CERT_MANAGER_SELFSIGNED_SECRET_NAME: wildcard-infra-sthings-tls
      CERT_MANAGER_SELFSIGNED_CERT_NAME: wildcard-infra-sthings-tls
      CERT_MANAGER_SELFSIGNED_CERT_NAMESPACE: default
      CERT_MANAGER_SELFSIGNED_ISSUER: cluster-ca
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: cilium-gateway
  namespace: flux-system
spec:
  interval: 1h
  retryInterval: 1m
  timeout: 5m
  dependsOn:
    - name: cilium-lb
    - name: cert-manager-selfsigned
  sourceRef:
    kind: GitRepository
    name: flux-infra
  path: ./infra/cilium/components/gateway
  prune: true
  wait: true
  postBuild:
    substitute:
      CILIUM_GATEWAY_NAME: infra-sthings-gateway
      CILIUM_GATEWAY_NAMESPACE: default
      CILIUM_GATEWAY_DOMAIN: "infra.sthings.lab"
      CILIUM_GATEWAY_TLS_SECRET: wildcard-infra-sthings-tls
---
EOF
```

```bash
# VERIFY CERTIFICATES ARE RE-ISSUED BY VAULT PKI
kubectl get certificates -A
kubectl get clusterissuer
```

```bash
# INIT + APPLY
terraform init
terraform plan

export VAULT_TOKEN=$(kubectl get secret vault-root-token -n vault -o jsonpath='{.data.root_token}' | base64 -d)

terraform apply --auto-approve
```


# GET CA CERT FROM VAULT
curl -sk https://vault.infra.sthings.lab/v1/pki/ca/pem -o sthings-lab-ca.crt

## INSTALL IT (UBUNTU)

```bash
sudo cp sthings-lab-ca.crt /usr/local/share/ca-certificates/sthings-lab-ca.crt
sudo update-ca-certificates
```

## INSTALL IT (MACOS)

```bash
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain sthings-lab-ca.crt
security find-certificate -c "sthings" /Library/Keychains/System.keychain
```


Change these two values to switch from cluster-ca to vault-pki:
vault Kustomization:
yamlISSUER_NAME: vault-pki        # was: cluster-ca
ISSUER_KIND: ClusterIssuer    # stays the same
cert-manager-selfsigned Kustomization:
yamlCERT_MANAGER_SELFSIGNED_ISSUER: vault-pki   # was: cluster-ca
```

So the flow becomes:
```
vault-pki (ClusterIssuer)
  → signs wildcard-infra-sthings-tls
    → used by cilium-gateway
      → TLS for all *.infra.sthings.lab routes including vault itself
After committing, force reconcile to pick up the changes immediately:
bash

```bash
flux reconcile kustomization vault --with-source
flux reconcile kustomization cert-manager-selfsigned --with-source
flux reconcile kustomization cilium-gateway --with-source

kubectl delete certificate wildcard-infra-sthings-tls -n default
kubectl delete secret wildcard-infra-sthings-tls -n default
flux reconcile kustomization cert-manager-selfsigned --with-source
```

Then verify the new cert is issued by vault-pki:

```bash
kubectl get certificate -A
kubectl describe certificate wildcard-infra-sthings-tls -n default | grep Issuer
```


# Securing Harvester UI with Vault PKI (Manual Cert Approach)

## Prerequisites

- Vault PKI running on infra cluster with `vault-pki` ClusterIssuer
- `harvester.sthings.lab` DNS resolving to `192.168.10.110`
- kubeconfigs for both clusters available

---
# 🔐 Harvester TLS Certificate Setup

> Complete guide for requesting, exporting, and applying a cert-manager certificate to Harvester via Vault PKI.

---

## 📋 Prerequisites

- Access to both `infra` and `harvester` kubeconfigs
- `cert-manager` with a `ClusterIssuer` named `vault-pki` configured on the infra cluster
- `kubectl`, `openssl` available locally

---

## Step 1 — Request Certificate from Infra Cluster

<details>
<summary>📜 Apply Certificate resource to infra cluster</summary>

```bash
export KUBECONFIG=~/.kube/infra.sthings.lab

kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: harvester-tls
  namespace: default
spec:
  secretName: harvester-tls
  issuerRef:
    name: vault-pki
    kind: ClusterIssuer
  commonName: harvester.sthings.lab
  dnsNames:
    - harvester.sthings.lab
  duration: 2160h
  renewBefore: 360h
EOF
```

</details>

---

## Step 2 — Export Cert and Key

<details>
<summary>💾 Extract TLS cert and key from the secret</summary>

```bash
kubectl get secret harvester-tls -n default \
  -o jsonpath='{.data.tls\.crt}' | base64 -d > harvester.crt

kubectl get secret harvester-tls -n default \
  -o jsonpath='{.data.tls\.key}' | base64 -d > harvester.key
```

</details>

---

## Step 3 — Import into Harvester

<details>
<summary>🚀 Create TLS secrets in the cattle-system namespace</summary>

```bash
export KUBECONFIG=~/.kube/harvester

# Create/replace the Rancher TLS secret
kubectl create secret tls tls-rancher \
  --cert=harvester.crt \
  --key=harvester.key \
  -n cattle-system \
  --dry-run=client -o yaml | kubectl apply -f -

# Create secret for ingress
kubectl create secret tls harvester-ingress-tls \
  --cert=harvester.crt \
  --key=harvester.key \
  -n cattle-system \
  --dry-run=client -o yaml | kubectl apply -f -
```

</details>

---

## Step 4 — Patch the Ingress

<details>
<summary>🔧 Patch rancher-expose ingress with TLS config</summary>

```bash
kubectl patch ingress rancher-expose -n cattle-system \
  --type merge \
  -p '{
    "spec": {
      "tls": [{
        "hosts": ["harvester.sthings.lab"],
        "secretName": "harvester-ingress-tls" # pragma: allowlist secret
      }],
      "rules": [{
        "host": "harvester.sthings.lab",
        "http": {
          "paths": [{
            "path": "/",
            "pathType": "Prefix",
            "backend": {
              "service": {
                "name": "rancher",
                "port": {"number": 80}
              }
            }
          }]
        }
      }]
    }
  }'
```

> **Note:** The backend service is `rancher:80` — not port 443.

</details>

---

## Step 5 — Verify

<details>
<summary>✅ Confirm the certificate is served correctly</summary>

```bash
echo | openssl s_client -connect harvester.sthings.lab:443 2>/dev/null \
  | openssl x509 -noout -issuer -subject
```

**Expected output:**

```
issuer=C=DE, O=sva, CN=sthings.lab
subject=CN=harvester.sthings.lab
```

</details>

---

## ⚠️ Important Notes

| Topic | Detail |
|---|---|
| **dynamiclistener** | Harvester uses it internally — replacing secrets alone is not enough, the ingress must be patched |
| **Backend port** | Use `rancher:80`, not 443 |
| **Cert renewal** | Manual — repeat steps 1–5 before expiry |
| **Expiry** | 90 days / 2160h |
| **Automation** | Consider cross-cluster Vault issuer with CoreDNS forwarding for `sthings.lab` |

---

---

# 🗄️ NFS Server Install

---

## Ansible Setup

<details>
<summary>🐍 Install Ansible in a Python venv</summary>

```bash
# Install venv package
sudo apt update && sudo apt install -y python3-venv python3-pip

# Create venv
python3 -m venv ~/.venv/ansible

# Activate
source ~/.venv/ansible/bin/activate

# Install specific ansible version
pip install ansible==11.13.0

# Verify
ansible --version
```

**Optional: Make activation permanent**

```bash
# Alias approach
echo "alias ansible-env='source ~/.venv/ansible/bin/activate'" >> ~/.bashrc

# Or auto-activate on shell start
echo 'source ~/.venv/ansible/bin/activate' >> ~/.bashrc
```

**Verify version:**

```bash
pip show ansible | grep Version
# Version: 11.13.0
```

> **Note:** Ansible 11.x corresponds to `ansible-core 2.18.x` — `ansible --version` will show the core version, which is expected.

</details>

---

## Run the NFS Playbook

<details>
<summary>▶️ Install NFS server via Ansible</summary>

```bash
ansible-galaxy install -r harvester/requirements.yaml

ansible-playbook sthings.baseos.nfs_server.yaml \
  -i "infra.sthings.lab," \
  -u sthings \
  --become \
  -e "nfs_network=192.168.10.0/24"
```

</details>

---

## NFS CSI Driver (Flux / HelmRelease)

<details>
<summary>🔍 Check NFS CSI pod status</summary>

```bash
kubectl get pods -n kube-system | grep -E 'csi-nfs|snapshot-controller'
kubectl get daemonset csi-nfs-node -n kube-system
kubectl get deployment csi-nfs-controller -n kube-system
```

</details>

<details>
<summary>🛠️ Fix stuck HelmRelease for nfs-csi</summary>

If the `HelmRelease/kube-system/nfs-csi` is stuck in **Failed** state, Flux won't proceed. Use the following steps to reset it:

**1. Check the failure reason:**

```bash
flux get helmrelease -n kube-system nfs-csi

# Full detail:
kubectl describe helmrelease -n kube-system nfs-csi
```

**2. Force reconcile:**

```bash
flux reconcile helmrelease nfs-csi -n kube-system --force
```

**3. If still stuck — suspend + resume:**

```bash
flux suspend helmrelease nfs-csi -n kube-system
flux resume helmrelease nfs-csi -n kube-system
```

**4. Reconcile the parent Kustomization:**

```bash
# Find the kustomization name first
flux get kustomizations -A | grep nfs-csi

# Then reconcile
flux reconcile kustomization nfs-csi -n flux-system --force
```

</details>

<details>
<summary>🔎 Diagnose lingering HelmRelease failures</summary>

If the HelmRelease keeps failing despite pods running, Helm chart health checks (readiness probes, jobs, hooks) may be timing out.

```bash
kubectl get events -n kube-system --sort-by='.lastTimestamp' | grep nfs-csi
helm history nfs-csi -n kube-system
```

> **Tip:** To prevent timeout issues in the future, increase the install timeout in your `HelmRelease` spec — the Deployment/DaemonSet may just need more time to become ready.

</details>

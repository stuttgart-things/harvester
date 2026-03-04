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
```
# XPLANE

<details open>
<summary>CREATE K3S CLUSTER + UPLOAD ENCRYPTED KUBECONFIG</summary>

```bash
dagger call -m github.com/stuttgart-things/blueprints/vm@v1.67.0 \
execute-ansible-encrypt-and-commit \
--playbooks "sthings.rke.k3s_cluster" \
--hosts xplane.sthings.lab \
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
--git-commit-message "Add encrypted kubeconfig for k3s cluster xplane" \
--git-destination-path "secrets" \
--git-token=env:GITHUB_TOKEN \
--progress plain -vv
```

</details>


<details open>
<summary>FLUX INIT + CILIUM CONFIG</summary>

```bash
dagger call -m github.com/stuttgart-things/blueprints/kubernetes-deployment@v1.67.0 \
flux-bootstrap \
--kube-config file:///home/sthings/.kube/xplane \
--deploy-operator=true \
--commit-to-git=true \
--repository stuttgart-things/harvester \
--destination-path "clusters/xplane" \
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


# 🔧 Crossplane Cluster Configuration via Dagger

> Uses the `crossplane-configuration` Dagger module from `stuttgart-things/blueprints` to generate SOPS-encrypted cluster configs.

---

```bash
# Set your AGE public key before running
export AGE_PUB=age1xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

---

## 🚀 Add Clusters

### in-cluster (xplane)

<details>
<summary>▶️ Generate encrypted config for <code>in-cluster</code></summary>

```bash
dagger call \
  -m github.com/stuttgart-things/blueprints/crossplane-configuration@v1.67.0 \
  add-cluster \
  --clusterName=in-cluster \
  --deploy-to-cluster=false \
  --kubeconfig-cluster file:///home/sthings/.kube/xplane \
  --encrypt-with-sops=true \
  --age-public-key=env:AGE_PUB \
  export \
  --path=/home/sthings/harvester/clusters/xplane/in-cluster-config.yaml \
  --progress plain \
  -vv
```

**Output:** `~/harvester/clusters/xplane/in-cluster-config.yaml`

</details>

---

### harvester

<details>
<summary>▶️ Generate encrypted config for <code>harvester</code></summary>

```bash
dagger call \
  -m github.com/stuttgart-things/blueprints/crossplane-configuration@v1.67.0 \
  add-cluster \
  --clusterName=harvester \
  --deploy-to-cluster=false \
  --kubeconfig-cluster file:///home/sthings/.kube/harvester \
  --encrypt-with-sops=true \
  --age-public-key=env:AGE_PUB \
  export \
  --path=/home/sthings/harvester/clusters/xplane/harvester-config.yaml \
  --progress plain \
  -vv
```

**Output:** `~/harvester/clusters/xplane/harvester-config.yaml`

</details>

---

## ⚙️ Flag Reference

| Flag | Value | Description |
|---|---|---|
| `--clusterName` | `in-cluster` / `harvester` | Name to register the cluster under |
| `--deploy-to-cluster` | `false` | Only generate config, don't apply it |
| `--kubeconfig-cluster` | `file:///home/sthings/.kube/<name>` | Path to the target cluster kubeconfig |
| `--encrypt-with-sops` | `true` | Encrypt output with SOPS |
| `--age-public-key` | `env:AGE_PUB` | AGE public key read from environment |
| `--progress` | `plain` | Plain text log output |
| `-vv` | — | Verbose logging |

---

## 📁 Output Structure

```
~/harvester/clusters/xplane/
├── in-cluster-config.yaml   # SOPS-encrypted
└── harvester-config.yaml    # SOPS-encrypted
```

---

## ⚠️ Notes

- `--deploy-to-cluster=false` means configs are **only written to disk** — no changes are applied to the cluster
- Output files are **SOPS-encrypted** with your AGE key — safe to commit to git
- Decryption requires the corresponding **AGE private key** (`SOPS_AGE_KEY` or `~/.config/sops/age/keys.txt`)


## INSTALL VAULT CA (ANSIBKE)

```bash
ansible-playbook clusters/infra/vault/install-ca-cert.yaml -i "infra.sthings.lab,xplane.sthings.lab" -u sthings --become
```


## INSTALL CLAIMS

```bash
cd /tmp
wget https://github.com/stuttgart-things/claims/releases/download/v0.7.2/claims_0.7.2_linux_amd64.tar.gz
tar xvfz claims_0.7.2_linux_amd64.tar.gz 
sudo mv claims /usr/bin/claims && sudo chmod +x /usr/bin/claims
claims version
```

```bash
export CLAIM_API_URL=https://claim-machinery-api.xplane.sthings.labc
claims render
```
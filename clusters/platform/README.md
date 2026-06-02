# PLATFORM.STHINGS.LAB

<details open>
<summary>OS-PREREQUISITES FOR ANSIBLE</summary>

```bash
ssh-copy-id sthings@platform.sthings.lab
ssh sthings@platform.sthings.lab

sudo cat /etc/sudoers
#....
# ...
Defaults env_reset
#Defaults use_pty

sthings ALL=(ALL) NOPASSWD: ALL

@includedir /etc/sudoers.d


sudo apt -y install python3.13-venv
sudo python3 -m venv /opt/k3s-venv  
sudo chown -R sthings:sthings /opt/k3s-venv

/opt/k3s-venv/bin/python3 -m ensurepip
/opt/k3s-venv/bin/python3 -m pip install --upgrade pip setuptools wheel packaging

/opt/k3s-venv/bin/pip list
/opt/k3s-venv/bin/python3 -c "import packaging; print(packaging.__version__)"
```

</details>

<details open>
<summary>CREATE K3S CLUSTER + UPLOAD ENCRYPTED KUBECONFIG</summary>

```bash
dagger call -m github.com/stuttgart-things/blueprints/vm@v1.70.0 \
execute-ansible-encrypt-and-commit \
--playbooks "sthings.rke.k3s_cluster" \
--hosts platform.sthings.lab \
--ssh-user=env:SSH_USER \
--ssh-password=env:SSH_PASSWORD \
--requirements=../../requirements.yaml \
--parameters "cilium_version=0.19.0 k3s_k8s_version=1.35.1 k3s_release_kind=k3s1 cluster_setup=singlenode fetched_kubeconfig_path=/tmp/k3s.yaml install_k3s=true k3s_state=present prepare_rancher_ha_nodes=true" \
--inventory-type cluster \
--age-public-key=env:AGE_PUB \
--export-paths "/tmp/k3s.yaml" \
--progress plain -vv \
--git-repository "stuttgart-things/harvester" \
--git-create-pr=true \
--git-pr-title="add platform cluster" \
--git-branch main \
--git-commit-message "Add encrypted kubeconfig for k3s cluster infra" \
--git-destination-path "secrets" \
--export-target-names=platform.sthings.lab.yaml \
--git-token=env:GITHUB_TOKEN \
--progress plain -vv
```

</details>

<details open>
<summary>DECRYPT + TEST KUBECONFIG</summary>

```bash
dagger call -m github.com/stuttgart-things/dagger/sops@v0.85.0 decrypt \
  --age-key env:SOPS_AGE_KEY \
  --encrypted-file ../../secrets/platform.sthings.lab.yaml \
  export --path=/home/sthings/.kube/platform.sthings.lab
```

```bash
export KUBECONFIG=/home/sthings/.kube/platform.sthings.lab
kubectl get nodes
```

</details>

<details open>
<summary>FLUX INIT + CILIUM CONFIG</summary>

```bash
dagger call -m github.com/stuttgart-things/blueprints/kubernetes-deployment@v1.70.0 \
flux-bootstrap \
--kube-config file:///home/sthings/.kube/platform.sthings.lab \
--deploy-operator=true \
--commit-to-git=true \
--repository stuttgart-things/harvester \
--destination-path "clusters/platform" \
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

<details open>
<summary>DNS ENTRY</summary>

```bash
address=/platform.sthings.lab/192.168.10.160
```

</details>

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

</details>

<details open>
<summary>CREATE CILIUM CONFIG</summary>






</details>

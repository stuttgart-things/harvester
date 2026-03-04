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
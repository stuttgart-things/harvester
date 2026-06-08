# K3S CLUSTER ON HARVESTER (single large VM)

Provision a single **large** Harvester VM (from the `u26-dev` image) and turn it
into a single-node k3s cluster via the stuttgart-things Ansible blueprints
(run through Dagger). Air-gapped: k3s + Cilium images are pre-loaded from the
internal mirror and docker.io is pulled through a harbor mirror.

The flow is:

1. `kubectl apply` the VM manifest on Harvester.
2. Wait for the VM to be `Running` and grab its DHCP IP.
3. Write that IP into the Ansible inventory (`inv`).
4. Run the Dagger Ansible provisioning to install k3s.

## Machine spec

| Field | Value |
|---|---|
| Name | `crossplane` |
| Image | `default/u26-dev` (Ubuntu 26 dev base, SSH-ready `sthings` user) |
| vCPU | 8 cores |
| Memory | 16 Gi |
| Root disk | 60 Gi (Longhorn, image-backed) |
| Network | `default/vms` NAD (bridged onto `mgmt-br`, DHCP from DD-WRT) |

See [`vm.yaml`](./vm.yaml).

## Prerequisites

- `KUBECONFIG` pointing at the Harvester cluster (`harvester.sthings.lab`).
- The `u26-dev` image present in the `default` namespace
  (see [../install.md](../install.md)).
- `dagger`, `kubectl` and `jq` on the workstation.
- SSH credentials for the `sthings` user exported as env vars:
  ```bash
  export SSH_USER=sthings
  export SSH_PASSWORD=<password>   # or use the key baked into the image
  ```

## 1. Apply the VM

```bash
kubectl apply -f vm.yaml
```

## 2. Wait for the VM and get its IP

```bash
# Wait until the VM reports Running
kubectl wait --for=jsonpath='{.status.printableStatus}'=Running \
  vm/crossplane -n default --timeout=300s

# Wait until the guest agent reports an IP, then capture it
until VM_IP=$(kubectl get vmi crossplane -n default \
  -o jsonpath='{.status.interfaces[0].ipAddress}' 2>/dev/null) && [ -n "$VM_IP" ]; do
  echo "waiting for VM IP..."; sleep 5
done
echo "VM IP: ${VM_IP}"
```

## 3. Write the IP into the inventory

```bash
sed -i "s/VM_IP_PLACEHOLDER/${VM_IP}/" inv
cat inv
```

## 4. Provision k3s with Dagger

```bash
dagger call -m github.com/stuttgart-things/blueprints/vm@v2.4.1 execute-ansible-encrypt-and-commit --src "." --playbooks ./plays.yaml --inventory ./inv --ssh-user=env:SSH_USER --ssh-password=env:SSH_PASSWORD --requirements-data requirements-data.yaml --parameters-file vars.yaml --git-repository "stuttgart-things/harvester" --git-branch main --git-commit-message "Add encrypted kubeconfig for k3s cluster infra" --git-destination-path "secrets" --git-token=env:GITHUB_TOKEN --export-paths "/tmp/kubeconfig.yaml" --age-public-key=env:AGE_PUB --progress plain -vv
```

The kubeconfig is fetched to `/tmp/kubeconfig.yaml` (see `fetched_kubeconfig_path`
in [`vars.yaml`](./vars.yaml)).

## Configuration

- **Provisioning Type**: k3s-cluster
- **Cluster Name**: k3s
- **Kubernetes Version**: 1.36.1+k3s1
- **Cluster Setup**: singlenode
- **CNI**: Cilium (kube-proxy replaced)
- **Air-gapped images**: k3s + Cilium tars pre-loaded from
  `artifacts.platform.sthings.lab` (`cilium_image_pull_policy: Never`)
- **Registry mirror**: docker.io → `docker.harbor.platform.sthings.lab`
  (fallback to upstream)

## Playbooks

See [plays.yaml](./plays.yaml) for the playbooks that will be executed.

## Variables

See [vars.yaml](./vars.yaml) for all configuration variables.

## Teardown

```bash
kubectl delete -f vm.yaml
```

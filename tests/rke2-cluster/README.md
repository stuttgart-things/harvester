# RKE2 CLUSTER ON HARVESTER (single large VM)

Provision a single **large** Harvester VM (from the `u26-dev` image) and turn it
into a single-node RKE2 cluster via the stuttgart-things Ansible blueprints
(run through Dagger).

The flow is:

1. `kubectl apply` the VM manifest on Harvester.
2. Wait for the VM to be `Running` and grab its DHCP IP.
3. Write that IP into the Ansible inventory (`inv`).
4. Run the Dagger Ansible provisioning to install RKE2.

## Machine spec

| Field | Value |
|---|---|
| Name | `rke2-test` |
| Image | `default/u26-dev` (Ubuntu 26 dev base, SSH-ready `sthings` user) |
| vCPU | 8 cores |
| Memory | 16 Gi |
| Root disk | 60 Gi (Longhorn, image-backed) |
| Network | `default/vms` NAD (bridged onto `mgmt-br`, DHCP from DD-WRT) |

See [`vm-rke2.yaml`](./vm-rke2.yaml).

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
kubectl apply -f vm-rke2.yaml
```

## 2. Wait for the VM and get its IP

```bash
# Wait until the VM reports Running
kubectl wait --for=jsonpath='{.status.printableStatus}'=Running \
  vm/rke2-test -n default --timeout=300s

# Wait until the guest agent reports an IP, then capture it
until VM_IP=$(kubectl get vmi rke2-test -n default \
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

## 4. Provision RKE2 with Dagger

```bash
dagger call -m github.com/stuttgart-things/blueprints/vm@v1.56.0 execute-ansible \
--src "." \
--playbooks ./plays.yaml \
--inventory ./inv \
--ssh-user=env:SSH_USER \
--ssh-password=env:SSH_PASSWORD \
--requirements-data requirements-data.yaml \
--parameters-file vars.yaml \
--progress plain -vv
```

The kubeconfig is fetched to `/tmp/kubeconfig` (see `fetched_kubeconfig_path`
in [`vars.yaml`](./vars.yaml)).

## Configuration

- **Provisioning Type**: rke2-cluster
- **Cluster Name**: rke2
- **Kubernetes Version**: 1.35.1
- **Cluster Setup**: singlenode
- **CNI**: Cilium (kube-proxy disabled)

## Playbooks

See [plays.yaml](./plays.yaml) for the playbooks that will be executed.

## Variables

See [vars.yaml](./vars.yaml) for all configuration variables.

## Teardown

```bash
kubectl delete -f vm-rke2.yaml
```

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
| Name | `crossplane` |
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

## 4. Provision RKE2 with Dagger

```bash
dagger call -m github.com/stuttgart-things/blueprints/vm@v2.4.1 execute-ansible-encrypt-and-commit --src "." --playbooks ./plays.yaml --inventory ./inv --ssh-user=env:SSH_USER --ssh-password=env:SSH_PASSWORD --requirements-data requirements-data.yaml --parameters-file vars.yaml --git-repository "stuttgart-things/harvester" --git-branch main --git-commit-message "Add encrypted kubeconfig for k3s cluster infra" --git-destination-path "secrets" --git-token=env:GITHUB_TOKEN --export-paths "/tmp/crossplane.yaml" --age-public-key=env:AGE_PUB --progress plain -vv
```

The kubeconfig is fetched to `/tmp/kubeconfig` (see `fetched_kubeconfig_path`
in [`vars.yaml`](./vars.yaml)).

## Configuration

- **Provisioning Type**: rke2-cluster
- **Cluster Name**: rke2
- **Kubernetes Version**: 1.35.1
- **Cluster Setup**: singlenode
- **CNI**: Cilium (kube-proxy disabled)
- **Registry mirror**: Harbor pull-through cache (`docker.harbor.platform.sthings.lab`)

## Registry mirror (Harbor pull-through cache)

`sthings.lab` reaches the internet through a **slow LTE router**. Pulling
container images straight from `docker.io` on every (re)provision saturates that
uplink and is the single biggest bottleneck when rebuilding clusters.

To make provisioning **fast and repeatable**, RKE2 is pointed at the Harbor
**pull-through-cache** that already runs on the platform cluster instead of
pulling from Docker Hub directly:

```yaml
# tests/crossplane/vars.yaml
registry_mirror_url: https://docker.harbor.platform.sthings.lab
```

The `sthings.rke.rke2_cluster` blueprint turns this into a containerd mirror in
`/etc/rancher/rke2/registries.yaml` on the node, so:

- the **first** pull of any docker.io image goes out over LTE once and is cached
  in Harbor;
- **every subsequent** pull — re-provisions, extra nodes, image churn — is served
  from the LAN at full speed, never touching the LTE link.

The cache itself is fully declared in GitOps (nothing to set up by hand), so a
rebuilt platform cluster reproduces it automatically:

| Piece | Where |
|---|---|
| Harbor (registry / cache only) | [`clusters/platform/apps/harbor.yaml`](../../clusters/platform/apps/harbor.yaml) |
| `docker` proxy-cache project | [`clusters/platform/apps/harbor-project-proxy.yaml`](../../clusters/platform/apps/harbor-project-proxy.yaml) |
| `*.harbor.<domain>` Gateway listener + wildcard cert | [`clusters/platform/infra.yaml`](../../clusters/platform/infra.yaml) |

> **CA trust (one-time gotcha).** The `*.harbor.platform.sthings.lab` cert is
> issued by the **`vault-pki` ClusterIssuer** (a self-signed homelab root), not a
> public CA. The RKE2 node must trust that root or the mirror fails the TLS
> handshake. Either:
>
> - install the vault-pki CA into the node trust store (e.g. bake it into the
>   `u26-dev` Packer image or drop it in `/usr/local/share/ca-certificates/`), or
> - let the blueprint emit a `configs:` entry with `tls.insecure_skip_verify: true`
>   for the mirror host (acceptable on the LAN-only homelab).
>
> Verify on the node after provisioning:
>
> ```bash
> cat /etc/rancher/rke2/registries.yaml        # mirror -> docker.harbor.platform.sthings.lab
> crictl pull docker.io/library/busybox:latest # should resolve via Harbor, not LTE
> ```

## Playbooks

See [plays.yaml](./plays.yaml) for the playbooks that will be executed.

## Variables

See [vars.yaml](./vars.yaml) for all configuration variables.

## Teardown

```bash
kubectl delete -f vm-rke2.yaml
```

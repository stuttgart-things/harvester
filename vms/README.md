# HARVESTER VMS

<details open>
<summary>BOOTSTRAP A VM END-TO-END (render + apply + wait + ansible)</summary>

For the first VM on a Harvester cluster, where no control plane exists yet to
provision against. `bake-harvester` renders the three manifests, applies them
through the Kubernetes API, waits for the guest agent to report an IP and runs
Ansible against it -- no OpenTofu and no Crossplane involved.

```bash
export KUBECONFIG=~/.kube/harvester

# DRY RUN FIRST -- renders the same manifests, touches no cluster
dagger call -m github.com/stuttgart-things/blueprints/vm@v3.2.0 \
  render-harvester-vm \
  --kcl-parameters-file ./vms/bootstrap-xplane.params.yaml \
  contents

# THE REAL RUN
dagger call -m github.com/stuttgart-things/blueprints/vm@v3.2.0 \
  bake-harvester \
  --kube-config file://$HOME/.kube/harvester \
  --vm-name bootstrap-xplane \
  --namespace default \
  --encrypted-file ./vms/bootstrap-xplane.params.enc.yaml \
  --sops-key env:SOPS_AGE_KEY \
  --ansible-playbooks "sthings.baseos.setup" \
  --ansible-parameters "manage_filesystem=false" \
  --ansible-user env:ANSIBLE_USER \
  --ansible-password env:ANSIBLE_PASSWORD \
  --progress plain -vv \
  export --path /tmp/bootstrap
```

`manage_filesystem=false` is not optional. Without it `sthings.baseos.setup`
fails on this VM with `Error while resolving value for 'lvm_device_auto':
'lvm_disk' is undefined` -- the role's LVM path wants a data disk that
bootstrap-xplane does not have. `vms/bootstrap-xplane.ansible-vars.yaml` holds
the same value for the `execute-ansible` entrypoint, which takes a file rather
than a string. Set it true and define `lvm_disk` if the VM ever gets a second
disk.

`--vm-name` wins over whatever the parameters say, so what gets applied and
what gets polled for cannot drift apart. `pvcName` and `secretName` are derived
from it (`<vm-name>-disk-0`, `<vm-name>-cloud-init`) unless the parameters set
them -- set them explicitly to attach a restored disk.

The credentials are NOT in `bootstrap-xplane.params.yaml`; see the note at the
bottom of that file for why leaving them unset is not the safe default it looks
like.

### Before the first run

Two things have to exist on the cluster, and neither is created by the run:

1. **The image.** `imageId` must name a real `VirtualMachineImage` in
   `imageNamespace` -- `kubectl get virtualmachineimages -n default`. The
   golden `sthings-*` images are the ones that accept the password auth
   `ANSIBLE_USER`/`ANSIBLE_PASSWORD` expect; a `*-dev` image trusts only the
   cloud-init key and Ansible fails with `Permission denied (publickey)`.

2. **The storage class the module composes.** `harvester-vm` 0.2.0 builds it as
   `<storageClass>-<imageId>` and offers no override, while Harvester names its
   own per-image classes `lh-<uuid>`. The two do not meet, and nothing rewrites
   the name -- the PVC is created against a class that does not exist, stays
   Pending, and the run trips `--vmi-appear-timeout` with the VirtualMachine
   applied but never instantiated. `vms/storageclass-longhorn-sthings-u26.yaml`
   is the alias that bridges it:

   ```bash
   kubectl apply -f vms/storageclass-longhorn-sthings-u26.yaml
   ```

   For a different image, copy `parameters.backingImage` from that image's
   generated class:

   ```bash
   kubectl get virtualmachineimage -n default <image> -o jsonpath='{.status.storageClassName}'
   ```

### The encrypted parameters

`bootstrap-xplane.params.enc.yaml` is the plaintext params plus
`cloudInitUsername`, `cloudInitPassword` and `cloudInitSshKey`, encrypted to the
repo's AGE recipient:

```bash
sops --encrypt --age <recipient> params-with-credentials.yaml \
  > vms/bootstrap-xplane.params.enc.yaml
```

`SOPS_AGE_KEY` must be exported for the run, and `cloudInitPassword` has to
match `ANSIBLE_PASSWORD` for the same user -- cloud-init's `chpasswd` overwrites
whatever the golden image baked in, so a mismatch boots a fine VM that Ansible
cannot log into.

</details>


<details open>
<summary>CREATE HARVESTER VM CONFIG + APPLY/CREATE</summary>

```bash
dagger call \
  -m github.com/stuttgart-things/dagger/kcl \
  run \
  --oci-source ghcr.io/stuttgart-things/harvester-vm:0.2.0 \
  --parameters "enablePvc=true,enableCloudConfig=true,enableVm=true,name=xplane-disk-0,namespace=default,imageId=upstream,storage=50Gi,storageClass=longhorn,vmName=xplane,hostname=xplane,secretName=xplane-cloud-init,pvcName=xplane-disk-0,cpuCores=12,memory=12Gi,description=xplane-vm" \
  export \
  --path ./harvester-xplane.yaml

export KUBECONFIG=~/.kube/harvester
kubectl apply -f ./harvester-xplane.yaml
```

</details>

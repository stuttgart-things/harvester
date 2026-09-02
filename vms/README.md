# HARVESTER VMS

<details open>
<summary>BOOTSTRAP A VM END-TO-END (render + apply + wait + ansible)</summary>

For the first VM on a Harvester cluster, where no control plane exists yet to
provision against. `bake-harvester` renders the three manifests, applies them
through the Kubernetes API, waits for the guest agent to report an IP and runs
Ansible against it -- no OpenTofu and no Crossplane involved.

The reproducible form is `vms/bake-bootstrap-xplane.sh` -- it is the call
below with the arguments filled in from the files in this directory, so a run
cannot drift from what is committed:

```bash
export SOPS_AGE_KEY=...                  # the repo's age key
./vms/bake-bootstrap-xplane.sh           # render only, touches no cluster
./vms/bake-bootstrap-xplane.sh apply     # the real run
```

It derives `ANSIBLE_USER`/`ANSIBLE_PASSWORD` from the encrypted parameters
rather than the environment, so the account Ansible authenticates as is by
construction the one cloud-init created, and builds `--ansible-parameters` from
`bootstrap-xplane.ansible-vars.yaml` so the string and the file cannot disagree.
`HARVESTER_KUBECONFIG` overrides the kubeconfig path.

What it runs, spelled out:

```bash
export KUBECONFIG=~/.kube/harvester

# DRY RUN FIRST -- renders the same manifests, touches no cluster
dagger call -m github.com/stuttgart-things/blueprints/vm@v3.2.1 \
  render-harvester-vm \
  --kcl-parameters-file ./vms/bootstrap-xplane.params.yaml \
  contents

# THE REAL RUN
dagger call -m github.com/stuttgart-things/blueprints/vm@v3.2.1 \
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

Both values below name things that already exist on the cluster; the run
creates neither.

1. **The image.** `imageId` must name a real `VirtualMachineImage` in
   `imageNamespace`. The golden `sthings-*` images are the ones that accept the
   password auth `ANSIBLE_USER`/`ANSIBLE_PASSWORD` expect; a `*-dev` image
   trusts only the cloud-init key and Ansible fails with
   `Permission denied (publickey)`.

2. **The storage class.** `storageClassName` must name the class Harvester
   generated for that image. Both come from one lookup:

   ```bash
   kubectl get virtualmachineimages -n default \
     -o custom-columns='NAME:.metadata.name,SC:.status.storageClassName'
   ```

   The UUID is per-image and per-cluster, so it cannot be carried between
   clusters or assumed stable across a re-import of the image.

   Leave `storageClassName` unset and harvester-vm falls back to composing
   `<storageClass>-<imageId>`, which is what 0.2.0 did unconditionally and what
   no current Harvester can satisfy (blueprints#197). That failure is silent:
   the PVC is created against a class that does not exist and stays Pending
   while the VirtualMachine looks applied, so the run trips
   `--vmi-appear-timeout` rather than reporting a bad class.

   `storageClassName` needs harvester-vm 0.3.0, which `vm@v3.2.1` pins. Use
   that tag. `v3.2.0` happens to honour the key too right now, but only because
   the `harvester-vm:0.2.0` OCI tag was overwritten with the 0.3.0 module --
   `kcl mod pull oci://ghcr.io/stuttgart-things/harvester-vm:0.2.0` reports
   `pulled harvester-vm 0.3.0`. That is a mutable tag, not a guarantee, and it
   means a `v3.2.0` pin no longer reproduces what it did this morning.

### Last verified run

`2026-09-02`, against the Harvester cluster in the lab, via
`./vms/bake-bootstrap-xplane.sh apply`:

```
Vm.bakeHarvester DONE [1m2s]
192.168.10.124 : ok=23  changed=4  unreachable=0  failed=0  skipped=27
```

PVC `Bound` to `lh-68e4c918-...` straight from `storageClassName`, VMI
`Running` with a guest-agent address after ~45s, Ansible authenticating as
`sthings` over password auth.

Worth knowing when you reproduce it: Dagger caches the Ansible step on the
contents of the generated inventory, i.e. the VM's IP. Rebuild the VM onto the
same address and the playbook is served from cache as `CACHED [0.0s]` with no
PLAY RECAP, while the run still reports success. `--cache-buster` does not help
-- it only reaches the requirements render (blueprints#199). To genuinely
re-run the playbook, use the module's `execute-ansible` against the host.

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

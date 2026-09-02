# HARVESTER VMS

<details open>
<summary>BOOTSTRAP A VM END-TO-END (render + apply + wait + ansible)</summary>

For the first VM on a Harvester cluster, where no control plane exists yet to
provision against. `bake-harvester` renders the three manifests, applies them
through the Kubernetes API, waits for the guest agent to report an IP and runs
Ansible against it -- no OpenTofu and no Crossplane involved.

Everything the run needs is in this directory as YAML; the call below is the
whole procedure.

| File | |
|---|---|
| `bootstrap-xplane.params.yaml` | VM shape -- image, disk, CPU/memory, network. No credentials. |
| `bootstrap-xplane.params.enc.yaml` | the same keys **plus** `cloudInitUsername`, `cloudInitPassword`, `cloudInitSshKey`, SOPS/AGE encrypted. Pass this **or** the plaintext file, never both. |
| `bootstrap-xplane.ansible-vars.yaml` | extra vars for the playbook, for the `execute-ansible` entrypoint which takes a file rather than a string. |

```bash
export KUBECONFIG=~/.kube/harvester
export SOPS_AGE_KEY=...                  # the repo's age key

# The Ansible credentials come OUT OF the encrypted parameters -- see below for
# why picking them by hand is how a run fails at the last step.
export ANSIBLE_USER=$(sops -d --extract '["cloudInitUsername"]' ./vms/bootstrap-xplane.params.enc.yaml)
export ANSIBLE_PASSWORD=$(sops -d --extract '["cloudInitPassword"]' ./vms/bootstrap-xplane.params.enc.yaml)

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

`ANSIBLE_USER`/`ANSIBLE_PASSWORD` have to be the credentials in the encrypted
file, which is why they are read from it above rather than typed. cloud-init's
`chpasswd` overwrites whatever the golden image baked in, so those are the only
credentials the VM will accept -- set them to anything else and the VM boots
correctly and rejects the playbook at watch-item 4.

Two values are written twice and nothing keeps them in step, so check both when
you change either: `manage_filesystem` (here as `--ansible-parameters`, and in
`bootstrap-xplane.ansible-vars.yaml`), and the module pin `vm@v3.2.1` (in both
calls above).

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

`2026-09-02`, against the Harvester cluster in the lab, with the call above
(`blueprints/vm@v3.2.1`):

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
<summary>INSTALL AN RKE2 CLUSTER ON THE VM</summary>

Turns `bootstrap-xplane` into a singlenode RKE2 cluster -- the control plane the
Crossplane management layer runs on. Same `bake-harvester` call as above with
three additions: the RKE2 playbook, the parameter set, and an inventory type.

```bash
export KUBECONFIG=~/.kube/harvester
export SOPS_AGE_KEY=...
export ANSIBLE_USER=$(sops -d --extract '["cloudInitUsername"]' ./vms/bootstrap-xplane.params.enc.yaml)
export ANSIBLE_PASSWORD=$(sops -d --extract '["cloudInitPassword"]' ./vms/bootstrap-xplane.params.enc.yaml)

dagger call -m github.com/stuttgart-things/blueprints/vm@v3.2.1 \
  bake-harvester \
  --kube-config file://$HOME/.kube/harvester \
  --vm-name bootstrap-xplane \
  --namespace default \
  --encrypted-file ./vms/bootstrap-xplane.params.enc.yaml \
  --sops-key env:SOPS_AGE_KEY \
  --ansible-playbooks "sthings.baseos.setup,sthings.rke.rke2_cluster" \
  --ansible-parameters "manage_filesystem=false rke_state=present rke2_k8s_version=1.35.3 rke2_release_kind=rke2r1 cluster_setup=singlenode cluster_name=xplane rke2_cni=none install_cilium=true disableKubeProxy=true rke2_airgapped_installation=true prepare_rancher_ha_nodes=true install_helm_diff=false registry_mirror_url=https://registry-1.docker.io fetched_kubeconfig_path=/tmp/kubeconfig" \
  --inventory-type cluster \
  --ansible-user env:ANSIBLE_USER \
  --ansible-password env:ANSIBLE_PASSWORD \
  --progress plain -vv \
  export --path /tmp/rke2-xplane
```

### `--inventory-type cluster` is required, and it is not cosmetic

`sthings.rke.rke2_cluster` declares `hosts: all`, but the role underneath it
branches on group membership -- `groups['initial_master_node']` for the install,
the token read and the kubeconfig rewrite, `groups['additional_master_nodes']`
for the join. The default inventory type produces

```ini
[all]
192.168.10.124
```

and the play fails on an undefined group before it does any work. `cluster`
produces what the role expects, empty groups included, because the role tests
membership *in* them:

```ini
# SINGLENODE-CLUSTER
[initial_master_node]
192.168.10.124 ansible_ssh_common_args='-o StrictHostKeyChecking=no'

[additional_master_nodes]

[workers]
```

The same trap in the Crossplane path is written up in the stuttgart-things
repo as `crossplane/knowledge/k3s-inventory-groups.md`.

### Note the two different separators

`--ansible-playbooks` is **comma**-separated. `--ansible-parameters` is
**space**-separated: the module passes that string through verbatim into
`ansible-playbook --extra-vars`, and ansible splits `k=v` pairs on whitespace.
Join the parameters with commas and the first key silently swallows the rest of
the string as its value.

### Collections

Nothing to supply. The module's default requirements set already carries
`sthings-rke`, the same release the Terraform profiles pin. `--ansible-requirements-file`
is only needed to deviate from it.

### The values, and why

| | |
|---|---|
| `rke2_cni=none` + `install_cilium=true` | Cilium is not an RKE2 built-in CNI; the role installs it via Helm and is gated on **both**. Set one without the other and you get either no CNI or RKE2's own Canal. |
| `rke2_airgapped_installation=true` | Matches the other RKE2 clusters in the lab. The role has a working default source, so no mirror URL is set. The archive download takes several minutes. |
| `manage_filesystem=false` | One 50Gi root disk, no data disk -- the role's LVM path has nothing to manage. |
| `fetched_kubeconfig_path=/tmp/kubeconfig` | Where the kubeconfig is fetched to inside the run; `export --path` brings it out. |

`vms/bootstrap-xplane.rke2.ansible-vars.yaml` holds the same values for the
`execute-ansible` entrypoint, which takes a file rather than a string. CI checks
that the two agree.

### Getting the kubeconfig out

`fetched_kubeconfig_path` fetches it *inside* the run. `export --path` does not
bring it out -- the exported directory holds `harvester-vm.yaml`,
`inventory.ini` and `outputs.json`, and nothing else. Take it off the node:

```bash
ssh sthings@<vm-ip> \
  'sudo cat /etc/rancher/rke2/rke2.yaml' \
  | sed "s/127.0.0.1/<vm-ip>/" > ~/.kube/xplane
```

The cloud-init key from the encrypted parameters is already trusted on the VM,
so this needs no password. The `sed` matters: the file RKE2 writes points at
`127.0.0.1`, which only works on the node itself.

### Last verified run

`2026-09-02`, `bake-harvester` with the call above, 14m40s end to end:

```
sthings.baseos.setup    : ok=23   changed=1   failed=0
sthings.rke.rke2_cluster: ok=124  changed=40  failed=0  unreachable=0
```

Checked on the node rather than taken from the recap, because a green recap
does not prove a working cluster:

```
NAME               STATUS   ROLES                VERSION
bootstrap-xplane   Ready    control-plane,etcd   v1.35.3+rke2r1
```

`cilium`, `cilium-envoy` and `cilium-operator` Running, no `kube-proxy`
DaemonSet, no Canal. Those two facts are what confirm `rke2_cni=none` +
`install_cilium=true` and `disableKubeProxy=true` actually took -- both fail
silently, into a working-looking cluster with the wrong CNI.

The air-gapped image archive was the slow step at roughly seven minutes of the
fourteen.

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

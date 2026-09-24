# HARVESTER VMS

VM parameter sets for `blueprints/vm`, and the two calls that turn one into a
running RKE2 cluster. `homerun2-dev` is the VM described in detail here; it
replaced `bootstrap-xplane`, which was retired along with its files.
`machinery-hv` follows the same calls with its own files -- see the section at
the end.

**The full runbook -- Clusterbook reservation, these bakes, the Flux bootstrap
and the infra components -- lives in
[`clusters/homerun2-dev/README.md`](../clusters/homerun2-dev/README.md).** Only
the VM half is repeated here, because that is what the files in this directory
are.

| File | |
|---|---|
| `homerun2-dev.params.yaml` | VM shape -- image, disk, CPU/memory, network. No credentials. |
| `homerun2-dev.params.enc.yaml` | the same keys **plus** `cloudInitUsername`, `cloudInitPassword`, `cloudInitSshKey`, SOPS/AGE encrypted. Pass this **or** the plaintext file, never both. |
| `homerun2-dev.rke2.ansible-vars.yaml` | the RKE2 extra vars, for the `execute-ansible` entrypoint which takes a file rather than a string. |

<details open>
<summary>BAKE A VM END-TO-END (render + apply + wait + ansible)</summary>

For the first VM on a Harvester cluster, where no control plane exists yet to
provision against. `bake-harvester` renders the three manifests, applies them
through the Kubernetes API, waits for the guest agent to report an IP and runs
Ansible against it -- no OpenTofu and no Crossplane involved.

```bash
export KUBECONFIG=~/.kube/harvester
export SOPS_AGE_KEY=...                  # the repo's age key

# The Ansible credentials come OUT OF the encrypted parameters -- see below for
# why picking them by hand is how a run fails at the last step.
export ANSIBLE_USER=$(sops -d --extract '["cloudInitUsername"]' ./vms/homerun2-dev.params.enc.yaml)
export ANSIBLE_PASSWORD=$(sops -d --extract '["cloudInitPassword"]' ./vms/homerun2-dev.params.enc.yaml)

# DRY RUN FIRST -- renders the same manifests, touches no cluster
dagger call -m github.com/stuttgart-things/blueprints/vm@v3.2.2 \
  render-harvester-vm \
  --kcl-parameters-file ./vms/homerun2-dev.params.yaml \
  contents

# BASE OS ONLY
dagger call -m github.com/stuttgart-things/blueprints/vm@v3.2.2 \
  bake-harvester \
  --kube-config file://$HOME/.kube/harvester \
  --vm-name homerun2-dev \
  --namespace default \
  --encrypted-file ./vms/homerun2-dev.params.enc.yaml \
  --sops-key env:SOPS_AGE_KEY \
  --ansible-playbooks "sthings.baseos.setup" \
  --ansible-parameters "manage_filesystem=false" \
  --ansible-user env:ANSIBLE_USER \
  --ansible-password env:ANSIBLE_PASSWORD \
  --progress plain -vv \
  export --path /tmp/homerun2-dev
```

`ANSIBLE_USER`/`ANSIBLE_PASSWORD` have to be the credentials in the encrypted
file, which is why they are read from it above rather than typed. cloud-init's
`chpasswd` overwrites whatever the golden image baked in, so those are the only
credentials the VM will accept -- set them to anything else and the VM boots
correctly and rejects the playbook at watch-item 4.

`manage_filesystem=false` is not optional. Without it `sthings.baseos.setup`
fails with `Error while resolving value for 'lvm_device_auto': 'lvm_disk' is
undefined` -- the role's LVM path wants a data disk this VM does not have. Set
it true and define `lvm_disk` only once the VM gets a second disk.

`--vm-name` wins over whatever the parameters say, so what gets applied and
what gets polled for cannot drift apart. `pvcName` and `secretName` are derived
from it (`<vm-name>-disk-0`, `<vm-name>-cloud-init`) unless the parameters set
them -- set them explicitly to attach a restored disk.

The credentials are NOT in `homerun2-dev.params.yaml`; see the note at the
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
   `--vmi-appear-timeout` rather than reporting a bad class. Never reintroduce a
   bare `storageClass:` key -- `vms-lint.yml` rejects it for this reason.

   `storageClassName` needs harvester-vm 0.3.0. Use `vm@v3.2.2`, which is the
   first tag that actually pins it: up to and including `v3.2.1` the module
   referenced the KCL module as `ghcr.io/stuttgart-things/harvester-vm:0.3.0`,
   an inline `:version` that kcl does not read as a pin at all. It parses the
   source with `url.Parse` and takes the version only from a `?tag=` query
   parameter, so the suffix stayed part of the repository path and the
   reference resolved to the newest published tag -- silently, while the string
   still read as pinned (blueprints#200).

   That is currently harmless here, because `harvester-vm` has only `0.2.0` and
   `0.3.0` published and 0.3.0 *is* the newest. It stops being harmless the day
   a 0.4.0 is pushed: every `v3.2.1` run would pick it up without a diff in this
   repo. The same mutability bit `v3.2.0` already -- the `harvester-vm:0.2.0`
   OCI tag was overwritten with the 0.3.0 module, and
   `kcl mod pull oci://ghcr.io/stuttgart-things/harvester-vm:0.2.0` reports
   `pulled harvester-vm 0.3.0`.

   `vms-lint.yml` enforces a single `blueprints/vm@` pin across this file, so
   the bump is all-or-nothing.

### A green run is not proof the playbook ran

Dagger caches the Ansible step on the contents of the generated inventory, i.e.
the VM's IP. Rebuild the VM onto the same address and the playbook is served
from cache as `CACHED [0.0s]` with no PLAY RECAP, while the run still reports
success. `--cache-buster` does not help -- it only reaches the requirements
render (blueprints#199). Require a `PLAY RECAP` in the output; to genuinely
re-run the playbook, use the module's `execute-ansible` against the host.

### The encrypted parameters

`homerun2-dev.params.enc.yaml` is the plaintext params plus
`cloudInitUsername`, `cloudInitPassword` and `cloudInitSshKey`, encrypted to the
repo's AGE recipient:

```bash
sops --encrypt --age <recipient> params-with-credentials.yaml \
  > vms/homerun2-dev.params.enc.yaml
```

`SOPS_AGE_KEY` must be exported for the run, and `cloudInitPassword` has to
match `ANSIBLE_PASSWORD` for the same user -- cloud-init's `chpasswd` overwrites
whatever the golden image baked in, so a mismatch boots a fine VM that Ansible
cannot log into.

</details>


<details open>
<summary>INSTALL AN RKE2 CLUSTER ON THE VM</summary>

Turns `homerun2-dev` into a singlenode RKE2 cluster. Same `bake-harvester` call
as above with three additions: the RKE2 playbook, the parameter set, and an
inventory type.

```bash
export KUBECONFIG=~/.kube/harvester
export SOPS_AGE_KEY=...
export ANSIBLE_USER=$(sops -d --extract '["cloudInitUsername"]' ./vms/homerun2-dev.params.enc.yaml)
export ANSIBLE_PASSWORD=$(sops -d --extract '["cloudInitPassword"]' ./vms/homerun2-dev.params.enc.yaml)

dagger call -m github.com/stuttgart-things/blueprints/vm@v3.2.2 \
  bake-harvester \
  --kube-config file://$HOME/.kube/harvester \
  --vm-name homerun2-dev \
  --namespace default \
  --encrypted-file ./vms/homerun2-dev.params.enc.yaml \
  --sops-key env:SOPS_AGE_KEY \
  --ansible-playbooks "sthings.baseos.setup,sthings.rke.rke2_cluster" \
  --ansible-parameters "manage_filesystem=false rke_state=present rke2_k8s_version=1.35.3 rke2_release_kind=rke2r1 cluster_setup=singlenode cluster_name=homerun2-dev rke2_cni=none install_cilium=true disableKubeProxy=true rke2_airgapped_installation=true prepare_rancher_ha_nodes=true install_helm_diff=false registry_mirror_url=https://registry-1.docker.io fetched_kubeconfig_path=/tmp/kubeconfig" \
  --inventory-type cluster \
  --ansible-user env:ANSIBLE_USER \
  --ansible-password env:ANSIBLE_PASSWORD \
  --progress plain -vv \
  export --path /tmp/homerun2-dev
```

`vms/homerun2-dev.rke2.ansible-vars.yaml` holds the same values for the
`execute-ansible` entrypoint; `vms-lint.yml` checks that the two agree, by
deriving the string from the file and requiring it in this README verbatim.

There is no `homerun2-dev.ansible-vars.yaml`: this VM is never baked with the
base OS profile alone. Add one if it ever is -- the lint derives a string from
whatever `*.ansible-vars.yaml` files exist and requires each to appear here.

### `--inventory-type cluster` is required, and it is not cosmetic

`sthings.rke.rke2_cluster` declares `hosts: all`, but the role underneath it
branches on group membership -- `groups['initial_master_node']` for the install,
the token read and the kubeconfig rewrite, `groups['additional_master_nodes']`
for the join. The default inventory type produces

```ini
[all]
192.168.10.117
```

and the play fails on an undefined group before it does any work. `cluster`
produces what the role expects, empty groups included, because the role tests
membership *in* them:

```ini
# SINGLENODE-CLUSTER
[initial_master_node]
192.168.10.117 ansible_ssh_common_args='-o StrictHostKeyChecking=no'

[additional_master_nodes]

[workers]
```

**Do not check this against the exported `inventory.ini`.** That file reads
`[all]` + the address even on a successful `cluster` run. The inventory Ansible
actually used is built inside the run and appears only in the log, as
`withNewFile inventory.ini (contents: "\n# SINGLENODE-CLUSTER\n...")`. Reading
the export to confirm the flag took gives exactly the wrong answer.

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
`sthings-rke`, the same release the Terraform profiles pin.
`--ansible-requirements-file` is only needed to deviate from it.

### The values, and why

| | |
|---|---|
| `rke2_cni=none` + `install_cilium=true` | Cilium is not an RKE2 built-in CNI; the role installs it via Helm and is gated on **both**. Set one without the other and you get either no CNI or RKE2's own Canal. The infra bundle needs Cilium specifically -- `cilium-lb` and `cilium-gateway` apply a `CiliumLoadBalancerIPPool` and a Gateway, which Canal cannot serve. |
| `rke2_airgapped_installation=true` | Matches the other RKE2 clusters in the lab. The role has a working default source, so no mirror URL is set. The archive download takes several minutes. |
| `manage_filesystem=false` | One 50Gi root disk, no data disk -- the role's LVM path has nothing to manage. |
| `fetched_kubeconfig_path=/tmp/kubeconfig` | Where the kubeconfig is fetched to inside the run. |

### Getting the kubeconfig out

`fetched_kubeconfig_path` fetches it *inside* the run, and `export --path` does
not bring it out -- the exported directory holds `harvester-vm.yaml`,
`inventory.ini` and `outputs.json`, nothing else. Take it off the node, reading
the address rather than assuming it:

```bash
NODE_IP=$(kubectl get vmi homerun2-dev -n default \
  -o jsonpath='{.status.interfaces[0].ipAddress}')

# The lease has probably been held by another machine before, so the known_hosts
# entry is stale and ssh refuses with REMOTE HOST IDENTIFICATION HAS CHANGED --
# in that state it also disables password auth.
ssh-keygen -f ~/.ssh/known_hosts -R "$NODE_IP"

ssh -o StrictHostKeyChecking=accept-new sthings@"$NODE_IP" \
  'sudo cat /etc/rancher/rke2/rke2.yaml' \
  | sed "s/127.0.0.1/$NODE_IP/" > ~/.kube/homerun2-dev
```

The cloud-init key from the encrypted parameters is already trusted on the VM,
so this needs no password. The `sed` matters: the file RKE2 writes points at
`127.0.0.1`, which only works on the node itself. And the node's address is a
DHCP lease, never the cluster's `192.168.10.171` -- that is the Cilium LB VIP
and answers for Services, not for the API server.

### Last verified run

`2026-09-17`, the call above, `Vm.bakeHarvester DONE [21m16s]`:

```
sthings.baseos.setup     : ok=23   changed=6   unreachable=0  failed=0  skipped=27
sthings.rke.rke2_cluster : ok=124  changed=40  unreachable=0  failed=0  skipped=74
```

Checked on the node rather than taken from the recap, because a green recap does
not prove a working cluster:

```
NAME           STATUS   ROLES                VERSION          INTERNAL-IP
homerun2-dev   Ready    control-plane,etcd   v1.35.3+rke2r1   192.168.10.117
```

Two DaemonSets, `cilium` and `cilium-envoy`; no `kube-proxy`, no Canal. Those
are what confirm `rke2_cni=none` + `install_cilium=true` and
`disableKubeProxy=true` actually took -- all three fail silently, into a
working-looking cluster with the wrong CNI. The air-gapped image archive was the
slow step, roughly half of the 21 minutes.

</details>

## machinery-hv

The Crossplane management cluster for this lab. Same two calls as above with
the name swapped; the whole build is in
[`clusters/machinery-hv/README.md`](../clusters/machinery-hv/README.md).

| File | |
|---|---|
| `machinery-hv.params.yaml` | 8 vCPU / 16Gi / 80Gi on `sthings-u26-26.924.1008`. No credentials. |
| `machinery-hv.params.enc.yaml` | the same keys plus `cloudInitUsername`, `cloudInitPassword`, `cloudInitSshKey` (`~/.ssh/id_ed25519.pub`, the key crossplane-mgmt's Harvester VMs already trust), SOPS/AGE encrypted. |
| `machinery-hv.rke2.ansible-vars.yaml` | the RKE2 extra vars, identical to homerun2-dev's apart from `cluster_name`. |

The parameter string for `bake-harvester`, kept here because `vms-lint.yml`
checks it against the vars file:

```bash
  --ansible-parameters "manage_filesystem=false rke_state=present rke2_k8s_version=1.35.3 rke2_release_kind=rke2r1 cluster_setup=singlenode cluster_name=machinery-hv rke2_cni=none install_cilium=true disableKubeProxy=true rke2_airgapped_installation=true prepare_rancher_ha_nodes=true install_helm_diff=false registry_mirror_url=https://registry-1.docker.io fetched_kubeconfig_path=/tmp/kubeconfig" \
```

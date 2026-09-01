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
  --kube-config file://~/.kube/harvester \
  --vm-name bootstrap-xplane \
  --namespace default \
  --encrypted-file ./vms/bootstrap-xplane.params.enc.yaml \
  --sops-key env:SOPS_AGE_KEY \
  --ansible-playbooks "sthings.baseos.setup" \
  --ansible-user env:ANSIBLE_USER \
  --ansible-password env:ANSIBLE_PASSWORD \
  --progress plain -vv \
  export --path /tmp/bootstrap
```

`--vm-name` wins over whatever the parameters say, so what gets applied and
what gets polled for cannot drift apart. `pvcName` and `secretName` are derived
from it (`<vm-name>-disk-0`, `<vm-name>-cloud-init`) unless the parameters set
them -- set them explicitly to attach a restored disk.

The credentials are NOT in `bootstrap-xplane.params.yaml`; see the note at the
bottom of that file for why leaving them unset is not the safe default it looks
like.

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

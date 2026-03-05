# XPLANE

```yaml
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: xplane-disk-0
  namespace: default
  annotations:
    harvesterhci.io/imageId: default/upstream
spec:
  accessModes:
  - ReadWriteMany
  resources:
    requests:
      storage: '50Gi'
  storageClassName: longhorn-upstream
  volumeMode: Block
---
apiVersion: v1
kind: Secret
metadata:
  name: xplane-cloud-init
  namespace: default
type: Secret
stringData:
  networkdata: ''
  userdata: |
    #cloud-config
    hostname: xplane
    ssh_pwauth: true
    users:
      - name: sthings
        sudo: ALL=(ALL) NOPASSWD:ALL
        lock_passwd: false
        shell: /bin/bash
        ssh_authorized_keys:
          - ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC...
    # Set password for user
    chpasswd:
      list: |
        sthings:Atlan7is
      expire: false
    package_update: true
    packages:
      - qemu-guest-agent
    runcmd:
      - - systemctl
        - enable
        - --now
        - qemu-guest-agent.service
---
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: xplane
  namespace: default
  labels:
    os: linux
  annotations:
    description: xplane-vm
spec:
  runStrategy: RerunOnFailure
  template:
    metadata:
      labels:
        vmName: xplane
    spec:
      hostname: xplane
      domain:
        machine:
          type: q35
        cpu:
          cores: 12
          sockets: 1
          threads: 1
        resources:
          limits:
            memory: '12Gi'
            cpu: '12'
        devices:
          disks:
          - name: disk-0
            disk:
              bus: virtio
            bootOrder: 1
          - name: cloudinitdisk
            disk:
              bus: virtio
          interfaces:
          - name: default
            bridge: {}
            model: virtio
          inputs:
          - name: tablet
            type: tablet
            bus: usb
        features:
          acpi:
            enabled: true
      evictionStrategy: LiveMigrateIfPossible
      networks:
      - name: default
        multus:
          networkName: default/vms
      volumes:
      - name: disk-0
        persistentVolumeClaim:
          claimName: xplane-disk-0
      - name: cloudinitdisk
        cloudInitNoCloud:
          secretRef:
            name: xplane-cloud-init
          networkDataSecretRef:
            name: xplane-cloud-init
      terminationGracePeriodSeconds: 120
```

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


<details open>
<summary>CREATE K3S CLUSTER + UPLOAD ENCRYPTED KUBECONFIG</summary>

```bash
dagger call -m github.com/stuttgart-things/blueprints/vm@v1.67.0 \
execute-ansible-encrypt-and-commit \
--playbooks "sthings.rke.k3s_cluster" \
--hosts xplane.sthings.lab \
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
--git-commit-message "Add encrypted kubeconfig for k3s cluster xplane" \
--git-destination-path "secrets" \
--git-token=env:GITHUB_TOKEN \
--progress plain -vv
```

</details>


<details open>
<summary>FLUX INIT + CILIUM CONFIG</summary>

```bash
dagger call -m github.com/stuttgart-things/blueprints/kubernetes-deployment@v1.67.0 \
flux-bootstrap \
--kube-config file:///home/sthings/.kube/xplane \
--deploy-operator=true \
--commit-to-git=true \
--repository stuttgart-things/harvester \
--destination-path "clusters/xplane" \
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
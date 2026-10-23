# ollama-gpu

A local LLM endpoint for Backstage RAG-AI ("Ask AI"), instead of the
OpenRouter free keys (20 requests/minute, models that come and go, catalog and
TechDocs sent to third parties). The Harvester host's **RTX 5060 Ti (16 GB)**
is passed through to one VM, which runs **Ollama** with a chat and an
embedding model behind its OpenAI-compatible `/v1` API. Tracking:
[harvester#526](https://github.com/stuttgart-things/harvester/issues/526).

| | |
|---|---|
| VM | `XVirtualMachine` [`ollama-gpu`](../../clusters/crossplane-mgmt/xrs/infra/ollama-gpu/xr-virtualmachine-harvester.yaml) on crossplane-mgmt: `large` (8 vCPU / 8 GiB / 128 GiB), `sthings-u26`, GPU as `hostDevices` |
| Software | [`sthings.container.ollama_gpu`](https://github.com/stuttgart-things/ansible/blob/main/collections/container/ollama_gpu.yaml): NVIDIA driver (open modules), Ollama as a systemd service, models |
| Models | `gemma3:12b` (chat, ~8 GB) + `bge-m3` (embeddings, ~1.2 GB), both kept loaded |
| Endpoint | `http://<vm-ip>:11434/v1` (`/v1/chat/completions`, `/v1/embeddings`, `/v1/models`) |
| Run | Dagger, [`stuttgart-things/dagger/ansible`](https://github.com/stuttgart-things/dagger/tree/main/ansible) `execute`, like [`hosts/matrix`](../matrix/README.md) |

Prerequisites from other repos:

- [crossplane-configurations#550](https://github.com/stuttgart-things/crossplane-configurations/pull/550):
  `hostDevices` in `harvester-vm` v0.1.14 / `virtual-machine` v0.1.16, merged and pushed.
- [ansible#1414](https://github.com/stuttgart-things/ansible/pull/1414):
  the `ollama_gpu` play, merged and released; its version goes into
  [`requirements.yml`](./requirements.yml).

## 1. Harvester: pass the GPU through

Once per host. Nothing here is GitOps.

1. **IOMMU on in the BIOS** (Intel VT-d / AMD-Vi, often "SVM"/"IOMMU" on AMD
   boards). Check on the Harvester node:

   ```bash
   ssh rancher@192.168.10.110 'sudo dmesg | grep -iE "DMAR|AMD-Vi|IOMMU" | head'
   ```

2. **Enable the `pcidevices-controller` add-on**: Harvester UI → Advanced →
   Add-ons → `pcidevices-controller` → Enable.
3. **Enable passthrough** for the GPU **and** its audio function (same IOMMU
   group): Advanced → PCI Devices → filter `NVIDIA` → select both → *Enable
   Passthrough*. That creates the `PCIDeviceClaim`s and binds both to
   `vfio-pci`. The host itself has no display on the card, so nothing is lost.
4. **Read the resource name** the VM has to ask for:

   ```bash
   export KUBECONFIG=~/.kube/harvester
   kubectl get pcidevices -o custom-columns=NAME:.metadata.name,RESOURCE:.status.resourceName,ADDR:.status.address,DRIVER:.status.kernelDriverInUse | grep -i nvidia
   kubectl get pcideviceclaims
   kubectl get node -o jsonpath='{.items[0].status.allocatable}' | tr ',' '\n' | grep -i nvidia
   ```

   The VGA function's `RESOURCE` goes into the XR's `deviceName`. The XR
   carries `nvidia.com/GB206_GEFORCE_RTX_5060_TI`, which is the expected
   form but **not verified**; correct it if the node advertises something
   else. An unknown name leaves the VMI `Pending` (unschedulable).

## 2. Crossplane: roll virtual-machine v0.1.16

After crossplane-configurations#550 is merged and both packages are pushed
(`BUMP=current task push` on `main`, harvester-vm first).

This PR raises the pin in
[`configuration-virtual-machine.yaml`](../../clusters/crossplane-mgmt/platform/virtual-machine/configuration-virtual-machine.yaml)
to v0.1.16. The package manager does **not** raise the already-installed
`harvester-vm` on its own, so patch it in place, then check for Lock duplicates.
The comment in that file and crossplane-configurations' `CLAUDE.md` have the
background.

```bash
export KUBECONFIG=~/.kube/crossplane-mgmt
kubectl patch configuration.pkg stuttgart-things-crossplane-configurations-harvester-vm --type=merge \
  -p '{"spec":{"package":"ghcr.io/stuttgart-things/crossplane-configurations/harvester-vm:v0.1.14"}}'
sleep 30
kubectl get configuration.pkg
kubectl get lock lock -o json | jq -r '.packages[].source' | sort | uniq -d    # must be empty
kubectl get xrd harvestervms.resources.stuttgart-things.com -o json | jq '.spec.versions[0].schema.openAPIV3Schema.properties.spec.properties.vm.properties | has("hostDevices")'   # true
```

## 3. The VM

The XR is under `clusters/crossplane-mgmt/xrs/infra/ollama-gpu/`. Argo CD
(`showcase-crossplane-xrs`, recurse + prune) applies it as soon as it is on
`main`. The base OS comes from the AnsibleRun (`sthings.baseos.setup`), as for
every `ansible: true` VM.

```bash
export KUBECONFIG=~/.kube/crossplane-mgmt
kubectl -n default get xvirtualmachine ollama-gpu -o jsonpath='{.status.share.ip}{"\n"}'
crossplane resource trace -n default xvirtualmachine ollama-gpu

# on Harvester: the VMI got the device
KUBECONFIG=~/.kube/harvester kubectl -n vms get vmi ollama-gpu -o jsonpath='{.spec.domain.devices.hostDevices}{"\n"}'

# in the guest
ssh sthings@<ip> 'lspci -nn -d 10de:'
```

Put the IP into [`inventory.ini`](./inventory.ini), and into the system
inventory once it is final (a static DHCP lease on the DD-WRT is the simplest
way to keep it).

If the VMI does not start with the device: harvester-vm pins memory hotplug
headroom (`memory.maxGuest` = 4× guest). Whether that is allowed together with
a VFIO device is unverified (crossplane-configurations#550, "Open risk").

## 4. Ollama, through Dagger

```bash
cd hosts/ollama-gpu
export SSH_USER=sthings SSH_PASSWORD='…'     # the golden image's credentials (ansible-credentials)

dagger -m github.com/stuttgart-things/dagger/ansible call execute \
  --src . \
  --requirements requirements.yml \
  --inventory inventory.ini \
  --playbooks sthings.container.ollama_gpu \
  --ssh-user env:SSH_USER \
  --ssh-password env:SSH_PASSWORD \
  --parameters "run_id=$(date +%s%N)" \
  --progress plain
```

The first run installs the driver, **reboots the VM** and pulls ~10 GB of
models. Give it 15–20 minutes. Success is the last assert of the play:

```
Ollama 0.40.10 on 0.0.0.0:11434 -- chat "ok", embedding dims 1024; NAME ... PROCESSOR 100% GPU ...
```

| Parameter | |
|---|---|
| `run_id` | **must change on every call**. Dagger caches the `ansible-playbook` step, so without it a second call replays the first result and never reaches the VM |
| `ollama_models` | e.g. `'{"ollama_models": ["qwen3:14b", "bge-m3"]}'`. Chat model first, embedding model last |
| `ollama_version` | Ollama release (default `0.40.10`) |
| `nvidia_driver_version` | Ubuntu driver branch (default `580`, ≥ 570 for the RTX 50xx) |
| `ollama_context_length` | default 16384. Too small and the RAG prompts are cut off silently |

## 5. Smoke test

```bash
IP=<vm-ip>
curl -s http://$IP:11434/v1/models | jq -r '.data[].id'
curl -s http://$IP:11434/v1/chat/completions -H 'Content-Type: application/json' \
  -d '{"model":"gemma3:12b","messages":[{"role":"user","content":"Was ist Harvester? Ein Satz."}]}' | jq -r '.choices[0].message.content'
curl -s http://$IP:11434/v1/embeddings -H 'Content-Type: application/json' \
  -d '{"model":"bge-m3","input":"stuttgart-things"}' | jq '.data[0].embedding | length'   # 1024
ssh sthings@$IP 'nvidia-smi; ollama ps'
```

## 6. Switch Backstage over

A separate PR against
[`clusters/platform/apps/backstage.yaml`](../../clusters/platform/apps/backstage.yaml),
under `postBuild.substitute`:

```yaml
BACKSTAGE_LLM_BASE_URL: http://<vm-ip>:11434/v1
BACKSTAGE_LLM_MODEL: gemma3:12b
BACKSTAGE_LLM_EMBEDDINGS_MODEL: bge-m3
```

`BACKSTAGE_LLM_API_KEY` in `backstage-secrets-subst` stays as it is. Ollama
ignores the key, but the plugin needs a non-empty one.

The embedding model changes the vector size, so **empty the embeddings and
re-index**:

```bash
export KUBECONFIG=~/.kube/platform
kubectl -n backstage exec -it rag-postgres-1 -- psql -d backstage_rag -c '\dt'     # find the embeddings table
kubectl -n backstage exec -it rag-postgres-1 -- psql -d backstage_rag -c 'TRUNCATE <table>;'
kubectl -n backstage rollout restart deploy/backstage-deployment
# then the two index calls from flux apps/backstage/README.md, "RAG-AI" step 5
```

With no rate limit any more, `embeddings.concurrencyLimit` (2 today, set for
the free models' 20 requests/minute) can go up later. That is a change in
flux `apps/backstage/pre-release.yaml`.

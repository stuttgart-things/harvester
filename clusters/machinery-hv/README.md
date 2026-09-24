# clusters/machinery-hv

The Crossplane management cluster for this lab, built **fresh, beside
crossplane-mgmt**, to run the same package set as the LabDA machinery cluster:
flux's `machinery` Crossplane profile, and with it the `ClusterStack` API that
[`app-dev.yaml`](https://github.com/stuttgart-things/stuttgart-things/blob/main/clusters/labda/vsphere/machinery-xrs/app-dev.yaml)
is written against.

**Status: scaffold.** Nothing here has been built. The VM, the Flux bootstrap
and the OpenBao mount follow the `homerun2-dev` runbook; the Crossplane half
has open points listed at the end.

| | |
|---|---|
| Cluster / VM name | `machinery-hv` |
| LB address | `192.168.10.178`, reserved in Clusterbook (`178:ASSIGNED:DNS:machinery-hv`) -- the Cilium VIP, not the node address |
| Domain | `machinery-hv.sthings.lab` |
| Kubernetes | RKE2 `v1.35.3+rke2r1`, Cilium, no kube-proxy |
| Harvester image | `sthings-u26-26.924.1008`, 8 vCPU / 16Gi / 80Gi |
| GitOps | Flux, syncing `clusters/machinery-hv`; flux bundles pinned to `v1.80.0` |
| Crossplane | profile `machinery` (catalog 0.10.0) |

## Why not upgrade crossplane-mgmt

crossplane-mgmt runs Crossplane v2.4.1, so the core is not the problem. Its
packages are: the older family (`rancher-cluster` v0.7.4, `virtual-machine`,
…), `namespace` / `volume-claim` and the Functions under **short** CR names,
Functions from both registries. The flux profile applies the same sources under
derived names, and one source under two CR names is a duplicate lock node --
every package goes `Healthy=False`. The profile README forbids exactly that
layering; `cluster` also needs `rancher-cluster >=v0.8.1`, and `tabletennis`
runs on the 0.7.4 one. stuttgart-things/flux#506 has the full history.

crossplane-mgmt keeps running `tabletennis` until its successor is built here.

## Layout

```
clusters/machinery-hv/              flux-system syncs this (recursively)
  git-repos.yaml                    flux-infra / flux-apps @ v1.80.0
  infra-platform.yaml               cilium, cert-manager + OpenBao issuer, openebs, UIs
  cicd-platform.yaml                crossplane (profile machinery) + tekton
  fleet-state.yaml                  -> ../machinery-hv-fleet-state   prune: true
  xrs.yaml                          -> ../machinery-hv-xrs           prune: FALSE
  openbao-pki-ca.yaml, openbao/     the cert-manager auth mount, as homerun2-dev
clusters/machinery-hv-fleet-state/  provider configs, EnvironmentConfigs, secrets
clusters/machinery-hv-xrs/          the ClusterStacks this cluster owns
vms/machinery-hv.*                  the VM shape and the RKE2 vars
```

The two content directories sit **beside** this one, not in it: flux-system
applies everything under `clusters/machinery-hv` recursively, so a subdirectory
would be applied twice, once without the `dependsOn` gates. Same arrangement as
the LabDA machinery cluster.

`config.yaml` and `secrets.yaml` do not exist yet -- the Flux bootstrap commits
them (step 4).

## Build, in order

Steps 1-6 are the [`homerun2-dev` runbook](../homerun2-dev/README.md) with the
name swapped; read its warnings there, they all apply.

1. **Reserve the LB address** -- done 2026-09-24, see
   [Log: 1](#1-lb-address-from-clusterbook-2026-09-24).
2. **Encrypted params, dry-run render, bake** -- see
   [Log: 2](#2-vm-parameters-dry-run-render-bake-2026-09-24).
3. **Fetch the kubeconfig** -- done 2026-09-24, see
   [Log: 3](#3-kubeconfig-off-the-node-2026-09-24). **Open:** the static DHCP
   lease for `be:64:f3:26:1a:60` -> `192.168.10.105` on the router --
   `homerun2-dev` lost its etcd peer URL to a lease change (harvester#238).
4. **Bootstrap Flux** with `--destination-path clusters/machinery-hv` and a
   `--branch-name`; add the two `detect-secrets` pragmas to the committed
   `config.yaml`.
5. **`kubectl apply -f clusters/machinery-hv/git-repos.yaml`.**
6. **`terraform apply` in `openbao/`**, then let `infra-platform` reconcile.
7. **Watch `cicd-platform`.** `kubectl get pkg` should show the catalog's set,
   all `Healthy`, with long CR names and no duplicates. Then read
   [the provider-kubeconfig note](../machinery-hv-fleet-state/README.md#provider-kubeconfig-watch-this-first).
8. **Fleet state**, steps A-D in
   [`../machinery-hv-fleet-state/README.md`](../machinery-hv-fleet-state/README.md).
9. **First order**: list `app-dev-hv.yaml` in
   [`../machinery-hv-xrs`](../machinery-hv-xrs/README.md) once the open points
   below are answered.

## Open points

- **`ClusterStack` with `provider: harvester` is not proven.** The XRD accepts
  it and names an EnvironmentConfig as a precondition
  (crossplane-configurations#258 Block B), but no golden test covers a
  ClusterStack on Harvester. Settle with `crossplane render` against the
  fleet-state EnvironmentConfigs before the first order -- in particular which
  `environmentConfig` value reaches the HarvesterVM child.
- **flux `crossplane-capabilities` cannot target this lab** (v1.80.0): the
  `CROSSPLANE_CAPABILITY_HARVESTER_*` variables are not passed to the child
  Kustomization, so the `harvester-demo` set always renders its defaults
  (`in-cluster`, `default/image-ubuntu`). Worked around in the fleet state;
  upstream: stuttgart-things/flux#514.
- **Argo CD registration.** The ClusterStack registers built clusters in Argo
  CD through the `argocd-cluster` Configuration; its preconditions on this lab
  (the Argo CD on platform, its provider config) are not in the fleet state yet.
- **No observability ApplicationSet on platform.** The `observability` profile
  is left out of `app-dev-hv.yaml` for that reason.

## Log -- the commands as they were run

Every command that touched something, in order, with what it returned.
Secrets are never inline: they come from `vms/machinery-hv.params.enc.yaml`
and from `SOPS_AGE_KEY`, which is exported by `~/.bashrc` on the workstation.

### 1. LB address from Clusterbook (2026-09-24)

The homerun2-dev runbook says to pass an explicit `ip`, because `.173`
(`ferdinand`) and `.178` (`martinwolf`) carried stale DNS records. Checked
first -- both are gone, so Clusterbook's auto-assignment is safe:

```bash
# the ledger: 5 of 8 free (.172 .173 .176 .178 .179)
curl -sk https://clusterbook.platform.sthings.lab/api/v1/networks/192.168.10/ips

# the method works (live clusters resolve) ...
dig +short headlamp.homerun2-dev.sthings.lab @192.168.10.1     # 192.168.10.171
# ... and the stale names do not, not even under a wildcard; no PTRs either
dig +short x.ferdinand.sthings.lab  @192.168.10.1              # (empty)
dig +short x.martinwolf.sthings.lab @192.168.10.1              # (empty)
for ip in 172 173 176 178 179; do dig +short -x 192.168.10.$ip @192.168.10.1; done   # (empty)
```

The router's dnsmasq options themselves could not be read: `ssh root@192.168.10.1`
refuses the workstation key (`Permission denied`). The check above is from the
outside only.

```bash
# reserve WITHOUT ip -- Clusterbook picks
curl -sk -X POST https://clusterbook.platform.sthings.lab/api/v1/networks/192.168.10/reserve \
  -H 'Content-Type: application/json' \
  -d '{"cluster":"machinery-hv","status":"ASSIGNED","create_dns":true}'
# {"cluster":"machinery-hv","digit":"178","dns":"ok","ip":"192.168.10.178",...}   HTTP 200

# both halves, not just the API answer
KUBECONFIG=~/.kube/platform.sthings.lab kubectl get networkconfig networks-labul -n clusterbook \
  -o jsonpath='{.spec.networks}' | tr ',' '\n' | grep 178      # "178:ASSIGNED:DNS:machinery-hv"
dig +short headlamp.machinery-hv.sthings.lab @192.168.10.1     # 192.168.10.178
```

Written into `CILIUM_LB_IP_START` / `_STOP` in [`infra-platform.yaml`](./infra-platform.yaml).

### 2. VM parameters, dry-run render, bake (2026-09-24)

The encrypted parameters were written by hand from a plaintext template kept
**outside** the repo, then shredded. SSH key: `~/.ssh/id_ed25519.pub`, the key
crossplane-mgmt's Harvester VMs already trust (`id_ed0815` is the matrix Pi's).

```bash
sops --encrypt --age age19vgzvmpt9tdlcsu8rzaacj397yz8gguz38nsmuy6eeelt5vjsyms542xtm \
  ~/machinery-hv.params-with-credentials.yaml \
  > vms/machinery-hv.params.enc.yaml
sops -d --extract '["vmName"]' vms/machinery-hv.params.enc.yaml   # machinery-hv
shred -u ~/machinery-hv.params-with-credentials.yaml
```

Dry run -- renders, touches no cluster. The first attempt died on a network
blip fetching the module (`Failed to connect to github.com:443`); the retry was
clean:

```bash
dagger call -m github.com/stuttgart-things/blueprints/vm@v3.2.2 \
  render-harvester-vm \
  --kcl-parameters-file ./vms/machinery-hv.params.yaml \
  contents
# PersistentVolumeClaim machinery-hv-disk-0   80Gi, default/sthings-u26-26.924.1008,
#                                             lh-fdd94630-26a5-4a13-8eed-d905fb9ddfdd
# Secret machinery-hv-cloud-init
# VirtualMachine machinery-hv                 8 cores, 16Gi, default/vms
```

Nothing named `machinery-hv` existed on Harvester beforehand
(`kubectl get vm,pvc,secret -n default` -> NotFound). The bake:

```bash
cd ~/harvester-machinery-hv
export KUBECONFIG=~/.kube/harvester
export ANSIBLE_USER=$(sops -d --extract '["cloudInitUsername"]' ./vms/machinery-hv.params.enc.yaml)
export ANSIBLE_PASSWORD=$(sops -d --extract '["cloudInitPassword"]' ./vms/machinery-hv.params.enc.yaml)

dagger call -m github.com/stuttgart-things/blueprints/vm@v3.2.2 \
  bake-harvester \
  --kube-config file://$HOME/.kube/harvester \
  --vm-name machinery-hv \
  --namespace default \
  --encrypted-file ./vms/machinery-hv.params.enc.yaml \
  --sops-key env:SOPS_AGE_KEY \
  --ansible-playbooks "sthings.baseos.setup,sthings.rke.rke2_cluster" \
  --ansible-parameters "manage_filesystem=false rke_state=present rke2_k8s_version=1.35.3 rke2_release_kind=rke2r1 cluster_setup=singlenode cluster_name=machinery-hv rke2_cni=none install_cilium=true disableKubeProxy=true rke2_airgapped_installation=true prepare_rancher_ha_nodes=true install_helm_diff=false registry_mirror_url=https://registry-1.docker.io fetched_kubeconfig_path=/tmp/kubeconfig" \
  --inventory-type cluster \
  --ansible-user env:ANSIBLE_USER \
  --ansible-password env:ANSIBLE_PASSWORD \
  --progress plain -vv \
  export --path /tmp/machinery-hv
```

(Run from the Claude Code session with the export path in its scratchpad
instead of `/tmp/machinery-hv`; nothing else differed.)

Result: `Vm.bakeHarvester DONE [11m2s]`, exit 0, and -- the part that counts --
a real `PLAY RECAP` from each playbook, in two separate dagger spans:

```
998 : sthings.baseos.setup      192.168.10.105 : ok=23   changed=5   unreachable=0  failed=0  skipped=27
1001: sthings.rke.rke2_cluster  192.168.10.105 : ok=124  changed=40  unreachable=0  failed=0  skipped=74
```

`ok=124 changed=40` is the recap homerun2-dev produced with the same playbook
set. The VM took `192.168.10.105` from DHCP. This log is also what
stuttgart-things/harvester#251 tests the workflow's per-playbook recap check
against.

### 3. Kubeconfig off the node (2026-09-24)

```bash
export KUBECONFIG=~/.kube/harvester
NODE_IP=$(kubectl get vmi machinery-hv -n default -o jsonpath='{.status.interfaces[0].ipAddress}')
MAC=$(kubectl get vmi machinery-hv -n default -o jsonpath='{.status.interfaces[0].mac}')
echo "$NODE_IP $MAC"            # 192.168.10.105 be:64:f3:26:1a:60

ssh-keygen -f ~/.ssh/known_hosts -R "$NODE_IP"
USER_=$(sops -d --extract '["cloudInitUsername"]' vms/machinery-hv.params.enc.yaml)
ssh -o StrictHostKeyChecking=accept-new -i ~/.ssh/id_ed25519 "$USER_@$NODE_IP" \
  'sudo cat /etc/rancher/rke2/rke2.yaml' \
  | sed "s/127.0.0.1/$NODE_IP/" > ~/.kube/machinery-hv
chmod 600 ~/.kube/machinery-hv
```

Checked on the node, not taken from the recap:

```bash
export KUBECONFIG=~/.kube/machinery-hv
kubectl get nodes -o wide
# machinery-hv   Ready   control-plane,etcd   v1.35.3+rke2r1   192.168.10.105   Ubuntu 26.04.1 LTS
kubectl -n kube-system get ds
# cilium         1/1
# cilium-envoy   1/1          -- and NO kube-proxy, NO canal
```

Encrypted the way every other kubeconfig here is stored (same age recipient as
`dagger … sops encrypt`), and proven to decrypt into a working one:

```bash
sops --encrypt --age age19vgzvmpt9tdlcsu8rzaacj397yz8gguz38nsmuy6eeelt5vjsyms542xtm \
  --input-type yaml --output-type yaml ~/.kube/machinery-hv > secrets/machinery-hv.yaml
sops -d secrets/machinery-hv.yaml | kubectl --kubeconfig /dev/stdin get nodes   # Ready
```

**Still open from this step:** the static lease on the router, `be:64:f3:26:1a:60`
-> `192.168.10.105`, hostname `machinery-hv` (docs/install.md). Until it exists
the node address and with it this kubeconfig are a 30-day lease.

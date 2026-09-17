# clusters/homerun2-dev

A singlenode RKE2 cluster on Harvester, built end to end with `dagger`: one VM,
one Ansible run, one Flux bootstrap, one infra bundle. It replaces
`bootstrap-xplane`, which is being torn down.

The whole procedure is below, in order. Everything it needs is committed in this
repo -- the VM shape and its credentials in [`vms/`](../../vms), the cluster's
own Flux objects here. `SOPS_AGE_KEY` is the only thing that is not.

| | |
|---|---|
| Cluster / VM name | `homerun2-dev` (the name is load-bearing: DNS, `cluster_name`, and the file names in `vms/`) |
| LB address | `192.168.10.171`, reserved in Clusterbook -- the Cilium VIP for Services, **not** the node's address (that is a DHCP lease, see step 3) |
| Domain | `homerun2-dev.sthings.lab` |
| Kubernetes | RKE2 `v1.35.3+rke2r1`, Cilium, no kube-proxy, no Canal |
| GitOps | Flux, syncing `clusters/homerun2-dev` |
| Harvester image | `sthings-u26`, 12 vCPU / 12Gi / 50Gi root disk |

```bash
export KUBECONFIG=~/.kube/harvester
export SOPS_AGE_KEY=...          # the repo's age key
export GITHUB_USER=... GITHUB_TOKEN=... AGE_PUB=...
```

---

## 1. Reserve the address and the DNS record

**Do this first.** The LB address is written by hand into
[`infra-platform.yaml`](./infra-platform.yaml), so it has to exist before the
infra layer is applied -- and reserving it afterwards risks Clusterbook handing
the same address to something else in between.

```bash
curl -sk -X POST \
  https://clusterbook.platform.sthings.lab/api/v1/networks/192.168.10/reserve \
  -H 'Content-Type: application/json' \
  -d '{"cluster":"homerun2-dev","status":"ASSIGNED","create_dns":true,"ip":"171"}'
```

**Pass `ip` explicitly.** Without it the handler picks with
`for digit := range networkIPs` -- Go map iteration, so the address you get is
neither the lowest free one nor the first in the ledger, but arbitrary. With
`ip` the request is exact and it never overwrites: a taken address answers
`409` naming the current holder, rather than silently taking it (that is
`assign`, which does overwrite by design).

`create_dns: true` writes `*.homerun2-dev.sthings.lab` onto the DD-WRT router's
dnsmasq options over SSH, which is what makes
`headlamp.homerun2-dev.sthings.lab` resolve later. Confirm both halves landed --
the API has answered `{"status":"ok"}` for a DNS write that never happened
(fixed in clusterbook v1.26.0, the instance here is v1.28.2):

```bash
export KUBECONFIG=~/.kube/platform.sthings.lab
kubectl get networkconfig networks-labul -n clusterbook -o jsonpath='{.spec.networks}' | tr ',' '\n'
# expect: "171:ASSIGNED:DNS:homerun2-dev"

dig +short headlamp.homerun2-dev.sthings.lab @192.168.10.1
```

> The ledger CR is the truth, not
> `clusters/platform-seeds/networkconfig-networks-labul.yaml`. That file is the
> seed only and carries `kustomize.toolkit.fluxcd.io/ssa: Ignore` precisely so
> Flux stops deleting live reservations on every reconcile.

`.173` and `.178` are free in the ledger but were `ferdinand` and `martinwolf`,
whose DNS records were left behind by a broken release path. Reusing either
makes two names resolve to one host. `.171` was never assigned.

---

## 2. Build the VM and the cluster

One call: renders the manifests, applies them, waits for the guest agent to
report an IP, then runs both playbooks against it. No OpenTofu, no Crossplane.

```bash
export KUBECONFIG=~/.kube/harvester
export ANSIBLE_USER=$(sops -d --extract '["cloudInitUsername"]' ./vms/homerun2-dev.params.enc.yaml)
export ANSIBLE_PASSWORD=$(sops -d --extract '["cloudInitPassword"]' ./vms/homerun2-dev.params.enc.yaml)

# DRY RUN FIRST -- renders the same manifests, touches no cluster
dagger call -m github.com/stuttgart-things/blueprints/vm@v3.2.2 \
  render-harvester-vm \
  --kcl-parameters-file ./vms/homerun2-dev.params.yaml \
  contents

# THE REAL RUN
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

Four things that are not optional, each of which fails quietly:

- **`--inventory-type cluster`.** `sthings.rke.rke2_cluster` declares
  `hosts: all`, but the role branches on `groups['initial_master_node']` and
  `groups['additional_master_nodes']`. The default type emits `[all]` plus the
  address and the play dies on an undefined group before doing any work.
- **The two separators.** `--ansible-playbooks` is **comma**-separated,
  `--ansible-parameters` is **space**-separated -- that string goes through
  verbatim into `--extra-vars`, which splits `k=v` on whitespace. Join the
  parameters with commas and the first key swallows the rest as its value.
- **`rke2_cni=none` *and* `install_cilium=true`.** Cilium is not an RKE2
  built-in; the role installs it via Helm gated on both. Set one without the
  other and you get either no CNI or RKE2's own Canal.
- **`manage_filesystem=false`.** One 50Gi root disk, no data disk -- the role's
  LVM path has nothing to manage and fails on an undefined `lvm_disk`.

> **A green run is not proof the playbook ran.** Dagger caches the Ansible exec
> on the contents of the generated inventory, i.e. the VM's IP. Rebuild onto the
> same address and it is served as `CACHED [0.0s]` with no `PLAY RECAP` while
> `bake-harvester` still exits 0. `--cache-buster` does not reach that exec
> (blueprints#199). Require a `PLAY RECAP` in the output; to genuinely re-run,
> use the module's `execute-ansible` against the host.

---

## 3. Take the kubeconfig off the node

`fetched_kubeconfig_path` fetches it *inside* the run, and `export --path` does
not bring it out -- the exported directory holds `harvester-vm.yaml`,
`inventory.ini` and `outputs.json`, nothing else.

**The node's address is not `192.168.10.171`.** That is the Cilium LB VIP,
announced for Services once the infra layer is up; the node itself takes a DHCP
lease out of `192.168.10.100-.149`. Read it, never assume it:

```bash
export KUBECONFIG=~/.kube/harvester
NODE_IP=$(kubectl get vmi homerun2-dev -n default \
  -o jsonpath='{.status.interfaces[0].ipAddress}')
echo "$NODE_IP"          # 192.168.10.117 on the first build

ssh sthings@"$NODE_IP" \
  'sudo cat /etc/rancher/rke2/rke2.yaml' \
  | sed "s/127.0.0.1/$NODE_IP/" > ~/.kube/homerun2-dev

kubectl --kubeconfig ~/.kube/homerun2-dev get nodes
```

The cloud-init key from the encrypted parameters is already trusted, so this
needs no password. The `sed` matters: RKE2 writes the file pointing at
`127.0.0.1`, which works only on the node itself.

> **That address is a lease, so the kubeconfig has a shelf life.** This is
> exactly how `bootstrap-xplane` died: it was built on `192.168.10.124`, came
> back from a rebuild on `.125`, and `secrets/xplane.yaml` kept pointing at the
> old address -- the cluster looked gone (`no route to host`) when only its
> address had moved. If this VM is ever rebuilt or reboots onto a new lease,
> redo this step and re-encrypt. A DHCP reservation on the router for the VM's
> MAC would remove the problem; there is none today.

Then commit it encrypted, the way every other cluster's kubeconfig is stored:

```bash
dagger call -m github.com/stuttgart-things/dagger/sops@v0.85.0 encrypt \
  --age-key env:AGE_PUB \
  --plaintext-file ~/.kube/homerun2-dev \
  --file-extension yaml \
  export --path=/home/sthings/harvester/secrets/homerun2-dev.yaml
```

---

## 4. Bootstrap Flux

```bash
dagger call -m github.com/stuttgart-things/blueprints/flux@v3.2.2 \
  bootstrap \
  --kube-config file:///home/sthings/.kube/homerun2-dev \
  --deploy-operator=true \
  --commit-to-git=true \
  --repository stuttgart-things/harvester \
  --destination-path "clusters/homerun2-dev" \
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
  --operator-version "0.47.0" \
  --wait-for-reconciliation=true \
  --progress plain
```

This commits `config.yaml` (the `FluxInstance`, with `sync.path:
clusters/homerun2-dev`) and `secrets.yaml` (SOPS: `git-token-auth` and
`sops-age`) into this directory. Pull them before editing anything here.

> **The module moved.** `clusters/{infra,xplane,platform}/README.md` all call
> `blueprints/kubernetes-deployment@v1.6x flux-bootstrap`. That module still
> exists but no longer carries the Flux functions -- they were extracted into
> `blueprints/flux` (#143), where the entrypoint is `bootstrap`. The flags are
> the same ones; `--operator-version` defaults to `0.47.0` here, where the older
> runbooks pinned `0.42.1`.

---

## 5. Git sources

`bootstrap` renders the `FluxInstance` and its secrets only. Without these two
`GitRepository` objects every Kustomization sits at "source not found":

```bash
kubectl --kubeconfig ~/.kube/homerun2-dev apply -f clusters/homerun2-dev/git-repos.yaml
```

Committed as [`git-repos.yaml`](./git-repos.yaml) so the FluxInstance keeps them
reconciled from here on.

---

## 6. The infra layer

[`infra-platform.yaml`](./infra-platform.yaml) is one Kustomization selecting
seven components from `stuttgart-things/flux` → `./infra/platform`. Once
committed, the FluxInstance syncing `clusters/homerun2-dev` applies it -- no
`kubectl` needed.

| Component | What it brings |
|---|---|
| `cilium-lb` | `CiliumLoadBalancerIPPool` pinned to `192.168.10.171/32` |
| `cilium-gateway` | the Gateway on that address, `homerun2-dev-sthings-gateway` |
| `cert-manager-install` | cert-manager (component default, currently v1.21.2) |
| `cert-manager-selfsigned` | self-signed CA + the `wildcard-tls` certificate for `*.homerun2-dev.sthings.lab` |
| `openebs` | local storage |
| `headlamp` | `https://headlamp.homerun2-dev.sthings.lab` |
| `flux-web` | `https://flux.homerun2-dev.sthings.lab` |

The bundle maps one `INFRA_DOMAIN` onto every base that needs a domain, so the
name is written once. Ordering comes from upstream `dependsOn`, not from the
list order -- but every prerequisite must be *selected*: Flux has no optional
dependency, so a missing one parks its dependent on "dependency not ready"
forever rather than erroring.

### Verify

A green Kustomization does not prove a working cluster; check the things that
fail silently:

```bash
export KUBECONFIG=~/.kube/homerun2-dev

kubectl get kustomization -n flux-system            # all Ready
kubectl get gateway -A                              # PROGRAMMED=True, address .171
kubectl get certificate -A                          # wildcard-tls Ready=True
kubectl -n kube-system get ds | grep -i kube-proxy  # expect NOTHING
kubectl -n kube-system get pods | grep -i cilium    # cilium, -envoy, -operator Running
curl -k https://headlamp.homerun2-dev.sthings.lab   # end to end through the Gateway
```

No `kube-proxy` DaemonSet and no Canal are what confirm `disableKubeProxy=true`
and `rke2_cni=none` + `install_cilium=true` actually took. Both fail into a
working-looking cluster with the wrong CNI.

---

## What this cluster does not have yet

- **No NFS.** `nfs-csi` is deliberately not selected. The lab's only NFS server
  is `infra.sthings.lab` (`/data/nfs/sthings`), and that host is slated to be
  switched off (#152) with no successor in this repo. Add
  `- ../components/nfs-csi` plus `NFS_SERVER_FQDN` and `NFS_SHARE_PATH` if that
  changes.
- **No ExternalSecrets, no OpenBao-backed PKI.** `cert-manager-selfsigned`
  issues the wildcard from a self-signed CA. The OpenBao path
  (`cert-manager-vault-issuer`, `external-secrets-vault-store`) needs a Vault
  Kubernetes auth mount that Flux cannot create -- it takes a Vault token and
  this cluster's API address, so it comes from
  `blueprints/argocd create-vault-kubernetes-auth --cluster-name homerun2-dev
  --auth-name eso`. Until that has run, a store would sit at
  `Ready=False / InvalidProviderConfig`.
- **No `homerun2` app.** Despite the name. The app bundle
  (`apps/platform/components/homerun2`) needs `external-secrets` **and** a
  `ClusterSecretStore` **and** KV entries (`redis-password`, `scout-auth-token`,
  the omni-pitcher token), i.e. the whole item above first. It is a second step,
  not part of this build.

---

## Retiring bootstrap-xplane

Once this cluster is up, `bootstrap-xplane` goes. It is already only a shell --
the VM runs but RKE2 does not answer, and its committed kubeconfig
(`secrets/xplane.yaml`) still points at `192.168.10.124`, an address the VM lost
when it was rebuilt onto `.125`.

```bash
export KUBECONFIG=~/.kube/harvester
kubectl delete virtualmachine bootstrap-xplane -n default
kubectl delete pvc bootstrap-xplane-disk-0 -n default
kubectl delete secret bootstrap-xplane-cloud-init -n default
```

Then drop from the repo: `secrets/xplane.yaml`, `clusters/bootstrap-xplane/`,
`vms/bootstrap-xplane.*`, and the `bootstrap-xplane` sections of
`vms/README.md`. Note `vms-bake.yml` defaults its `vm_name` input to
`bootstrap-xplane` -- repoint it at `homerun2-dev` in the same change.

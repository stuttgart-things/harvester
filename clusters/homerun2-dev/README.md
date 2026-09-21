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

  Do not check this against the `inventory.ini` in the exported directory: that
  one reads `[all]` + the address even on a successful `cluster` run. The
  inventory Ansible actually used is built inside the run and only visible in
  the log, as `withNewFile inventory.ini (contents: "\n# SINGLENODE-CLUSTER\n
  [initial_master_node]\n...")`. The exported file is not evidence of what ran.
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

# The lease has almost certainly been held by another machine before, so the
# key in known_hosts is stale and ssh refuses with REMOTE HOST IDENTIFICATION
# HAS CHANGED -- it also disables password auth in that state, so this is not
# something --ansible-password can paper over. Drop the old entry first.
ssh-keygen -f ~/.ssh/known_hosts -R "$NODE_IP"

ssh -o StrictHostKeyChecking=accept-new sthings@"$NODE_IP" \
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

`--branch-name` is not optional here either. It defaults to `main`, and this
cluster was built on a branch -- without it the module commits a FluxInstance
and its SOPS secrets straight onto `main`, outside the PR that is reviewing
them.

### The committed `config.yaml` needs two hand-edits, every time

The bot commits it, and as committed it **fails `pre-commit`**. `detect-secrets`
matches two lines on the keyword alone and both need an inline pragma:

```yaml
    - patch: |- # pragma: allowlist secret      # the /spec/decryption patch
    pullSecret: git-token-auth # pragma: allowlist secret
```

Neither is a credential: the first is a JSON-patch literal that merely *names*
`sops-age`, the second names the pull Secret. `clusters/xplane/config.yaml`
carries exactly these two pragmas at lines 28 and 54 -- someone hit this before
and fixed it by hand, and the fix cannot be upstreamed into the renderer from
here. Expect to redo it whenever `flux-bootstrap` regenerates the file.

That is also why the CI turned red the moment the bot pushed: the failing check
was `Pre-Commit (Dagger)` on the bot's own commit, not on anything written by a
human.

### The first reconcile cannot work until the cluster is on main

`flux-bootstrap` renders `refs/heads/main`, which is right for every cluster
here -- and it cannot resolve while `clusters/homerun2-dev` exists only on a
branch. Between #218 opening and merging, Flux fetched main, found no such path,
and parked with

```
gitrepository/flux-system   refs/heads/main@sha1:92d9855f   READY=True
kustomization/flux-system   READY=False
  kustomization path not found: stat /tmp/.../clusters/homerun2-dev: no such file or directory
```

Note which object reports the failure. The GitRepository is **Ready** -- it
fetched main perfectly well. Only the Kustomization fails, and its message names
a temp directory rather than the branch, so this reads like a broken path in
this repo rather than a cluster pointed at a revision that does not carry it.

The bridge was to point `spec.sync.ref` at the branch until #218 merged, then
put it back. It is back: this cluster syncs `refs/heads/main`, and
`config.yaml` matches `clusters/xplane/config.yaml` line for line apart from the
path and the operator version.

If you ever need that bridge again, the rule that makes it work is this: the
value lives in **two** places -- `spec.sync.ref` in `config.yaml` and the live
FluxInstance -- and they have to move together. `config.yaml` sits *inside* the
synced path, so patching only the cluster is undone by the next reconcile about
a minute later, and editing only the file changes nothing until the cluster is
already syncing the revision that carries it.

Order matters on the way back, too: merge first, then patch the live instance to
`main`, then delete the branch. Deleting the branch while the cluster still
points at it takes the GitOps root away with it.

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

### Last verified run

`2026-09-17`, steps 1-3 with the calls above. `Vm.bakeHarvester DONE [21m16s]`,
both plays with a real `PLAY RECAP` -- which is the point, since a cached
Ansible step reports success with no recap at all:

```
sthings.baseos.setup     : ok=23   changed=6   unreachable=0  failed=0  skipped=27
sthings.rke.rke2_cluster : ok=124  changed=40  unreachable=0  failed=0  skipped=74
```

`ok=124 changed=40` is the same recap `bootstrap-xplane` produced on
2026-09-02, against the same playbook set.

Checked on the node rather than taken from the recap:

```
NAME           STATUS   ROLES                VERSION          INTERNAL-IP
homerun2-dev   Ready    control-plane,etcd   v1.35.3+rke2r1   192.168.10.117

NAME           DESIRED   CURRENT   READY
cilium         1         1         1
cilium-envoy   1         1         1
```

Two DaemonSets, both Cilium's; no `kube-proxy`, no Canal. The air-gapped image
archive was again the slow step, roughly half of the 21 minutes.

The node took `192.168.10.117` from DHCP. `192.168.10.171` stays the LB VIP and
is not reachable until `cilium-lb` and `cilium-gateway` have reconciled.

Steps 4-6 followed on the same day. All nine Kustomizations Ready, four Helm
releases installed (cert-manager v1.21.2, headlamp 0.45.0, openebs 4.6.1,
flux-web), and the Gateway holding the reserved address:

```
gateway/homerun2-dev-sthings-gateway   cilium   192.168.10.171   PROGRAMMED=True
certificate/cluster-ca     True
certificate/wildcard-tls   True
```

Proven end to end rather than by resource status, which is the only version
worth recording:

```
$ curl -sk -o /dev/null -w '%{http_code} %{remote_ip}\n' https://headlamp.homerun2-dev.sthings.lab/
200 192.168.10.171
*  subject: CN=*.homerun2-dev.sthings.lab
*  issuer: CN=cluster-ca
```

That is the whole chain in one line: the Clusterbook wildcard resolves, Cilium
announces the VIP, the Gateway terminates TLS with the wildcard its own
`cert-manager-selfsigned` issued, and the HTTPRoute reaches the pod. Both
listeners report `attached=2`.

`ciliumloadbalancerippool/default-pool` shows `IPS AVAILABLE 0`, which is
correct and not a warning: the pool is a `/32` and the Gateway Service holds
its one address.

---

## 7. The homerun2 application stack

[`homerun2.yaml`](./homerun2.yaml) is **two** Flux Kustomizations: the stack,
then its HTTPRoutes once the stack is Ready. Both point at
`./apps/homerun2/root`, an empty selection target, and list the components they
want in `spec.components` -- ten components in the stack, eight routes.
Credentials come from
[`homerun2-secrets-subst.enc.yaml`](./homerun2-secrets-subst.enc.yaml), which
Flux decrypts with the same `sops-age` key it uses for everything else here.

### Why `/sops` on every component line

Each component that reads a credential appears twice in the list: the workload,
then its credential mode.

```yaml
    - ../components/omni-pitcher
    - ../components/omni-pitcher/sops
```

`sops/` renders ordinary Secrets whose values arrive through `substituteFrom`,
so the credentials live in this repo, encrypted, and the cluster needs no ESO
at all. `HOMERUN2_SECRET_STORE` and `HOMERUN2_SECRET_PATH` do not appear
anywhere in the rendered output.

`eso/` is the other mode: ExternalSecrets against a `ClusterSecretStore`. It
needs `external-secrets` and `external-secrets-vault-store` in the infra
bundle, plus a Vault Kubernetes auth mount that Flux cannot create -- it takes
a Vault token and this cluster's API address, so it comes from
`blueprints/argocd create-vault-kubernetes-auth --auth-name eso`. Switching
this cluster over later is a search-and-replace of `/sops` for `/eso` in those
lines, plus those two infra components and the mount. Nothing else here moves.

### Why not the apps-platform bundle

It would work: the bundle's homerun2 components take `HOMERUN2_SECRETS: sops`
and switch the same way (flux, `apps/platform/README.md`). Two things keep this
cluster on its own Kustomizations.

Its `homerun2` component is a fixed set -- omni-pitcher, core-catcher, scout,
led-catcher -- and this cluster also runs **notification-catcher**, with
`DRY_RUN` off. That second part cannot go through a bundle at all:
`postBuild.substitute` is `map[string]string`, kustomize drops the quotes
around `"${VAR:-true}"` because the bare form round-trips to the same string,
and envsubst then hands the API server a YAML bool, which is rejected -- taking
the parent apply and every sibling component with it. Written out here,
`"false"` is a literal and lands as a string.

The bundle is the better answer for a cluster that wants the standard set. This
one wants a different one, and `spec.components` is exactly the mechanism for
saying so.

### The four values

| Variable | Used by | Generated with |
|---|---|---|
| `HOMERUN2_REDIS_PASSWORD` + `HOMERUN2_REDIS_PASSWORD_B64` | redis-stack and every client; the same secret in two encodings, kept in step | `openssl rand -hex 24` |
| `HOMERUN2_OMNI_PITCHER_AUTH_TOKEN` | the `/pitch` bearer | `openssl rand -hex 32` |
| `HOMERUN2_SCOUT_AUTH_TOKEN` | scout | `openssl rand -hex 32` |
| `TEAMS_WEBHOOK_URL` | notification-catcher | reused from `clusters/platform/apps/argocd-notifications-secret.enc.yaml` |

The two auth tokens carry a `:-changeme` default upstream. A missing value
therefore does **not** fail the build -- it installs the literal string
`changeme` as the bearer token. `substituteFrom` is `optional: false` for the
same class of reason.

### Two traps that are already handled

- **`HOMERUN2_REDIS_STORAGE_CLASS` must be set.** Its default is `standard`,
  which does not exist here; `openebs-hostpath` is the only class on this
  cluster. Unset, the PVC never binds while the HelmRelease reports installed.
- **The `route` components use the ORIGINAL variable names** -- `DOMAIN`,
  `GATEWAY_NAME`, `GATEWAY_NAMESPACE`, not the `INFRA_*` names the infra bundle
  introduced. They must carry the same values as `infra-platform.yaml`'s
  `INFRA_*`, or the routes attach to nothing.

And one that needs no handling, contrary to appearances: the redis-stack
HelmRelease embeds start scripts full of `${REDIS_PASSWORD}`, `${CMD}`,
`${BASEDIR}` and friends. Flux replaces every undefined `${var}` with an empty
string, so this looks like it would shred the scripts -- but upstream escapes
all eleven of them as `$${var}`, which Flux renders back to a literal `${var}`
for the shell. A grep for `${VAR}` matches inside `$${VAR}` and will tell you
otherwise; count `$${` separately before believing it.

### Redis is held at chart 17.x deliberately

`HOMERUN2_REDIS_VERSION` is `17.1.4` while 22.0.7 exists. That is a pin, not
drift: upstream holds it with `allowedVersions: "<18.0.0"` (flux#454). 22.x
needs `global.security.allowInsecureImages` for the stuttgart-things
redis-stack-server and sentinel images, moves the password to
`REDIS_PASSWORD_FILE` and hardens the pod security context, none of it tested
against these start scripts. Migrating is its own change.

### The ten components, and the eight Kustomizations that used to be two

The stack list is redis-stack, omni-pitcher, core-catcher, notification-catcher,
scout, led-catcher, light-catcher, wled-mock, demo-pitcher and config-viewer.
Four of those arrived one at a time, and each cost an upstream pull request:

| Component | Needed upstream | Added by |
|---|---|---|
| led-catcher | flux#479, a `base-led-catcher` profile pair | #227 |
| light-catcher + wled-mock | flux#481, a `base-light-catcher` profile pair | #228 |
| demo-pitcher | flux#482, a `base-demo-pitcher` profile pair | #229 |
| config-viewer | none | #233 |

The reason was structural. A Flux Kustomization's `path` has to name a
directory kustomize can build, and a `kind: Component` directory is not one --
so a component could only be deployed through a `profiles/` directory that
selected it, and every profile carrying those three selected the `eso/`
variant. A `sops/` counterpart had to be created upstream before this cluster
could use them, and each came as its own pair of Kustomizations here: eight in
total for one app stack, 482 lines.

`apps/homerun2/root` removed the reason. It is an empty selection target, so
the composition is the list in this file and the next component is a line in
it. config-viewer needed nothing upstream even then, because it holds no
credentials -- `components/config-viewer` has neither an `eso/` nor a `sops/`
directory, which is why it is one line rather than two.

Two things to expect when reading the cluster back:

- **Most components appear TWICE in `flux get kustomizations -A`.** Each is a
  kustomize Component rendering its own `OCIRepository` plus a child
  Kustomization of the same name in namespace `homerun2`. The two in
  `flux-system` with source `flux-apps` are ours (`homerun2`,
  `homerun2-routes`); the ones in `homerun2` with an OCI source are the
  children. Same name, different namespace -- not a conflict.
- **The routes Kustomization uses `DOMAIN`, `GATEWAY_NAME` and
  `GATEWAY_NAMESPACE`** -- not the `INFRA_*` names. Same values, different
  spelling; see the trap above.

### Migrating from the eight

The objects do not change -- the two lists render exactly what the eight
profiles did, object for object -- but their **owner** does. When
`homerun2-led-catcher`, `homerun2-light-catcher`, `homerun2-demo-pitcher`,
`homerun2-config-viewer` and their `-routes` twins disappear from this file,
Flux prunes what they own while `homerun2` and `homerun2-routes` create the
same names, and the two are not ordered against each other.

Left alone that is a recreate: those five workloads and five routes go away and
come back, a minute or two of 404 on a dev cluster. To avoid it, annotate the
live objects first so the new owner adopts them instead:

```bash
kubectl -n homerun2 annotate kustomization,ocirepository,httproute \
  --all kustomize.toolkit.fluxcd.io/prune=disabled
```

Flux strips that annotation itself on its next apply. This is the same dance
`apps/homerun2/profiles/base/README.md` documents for the routes split, which
went through platform-sthings on 2026-09-11 with no 404.

One operational note on config-viewer: it reads Deployments and ConfigMaps in
its own namespace through the Kubernetes API (`get` and `list`, nothing more --
the RBAC ships with its base) and selects them with
`app.kubernetes.io/part-of=homerun2`. A component without that label is simply
absent from the view, which reads as an empty panel rather than an error.

---

## What this cluster does not have yet

- **No NFS.** `nfs-csi` is deliberately not selected. The lab's only NFS server
  is `infra.sthings.lab` (`/data/nfs/sthings`), and that host is slated to be
  switched off (#152) with no successor in this repo. Add
  `- ../components/nfs-csi` plus `NFS_SERVER_FQDN` and `NFS_SHARE_PATH` if that
  changes.
- **No ExternalSecrets.** There is no `external-secrets` and no
  `ClusterSecretStore` on this cluster, and the homerun2 stack does not need
  one: every component selects its `sops/` variant, whose credentials come from
  a SOPS-encrypted `substituteFrom` Secret in this repo. Adding ESO later means
  `external-secrets` + `external-secrets-vault-store` in the bundle and a
  second OpenBao auth mount (`eso`, policy `read-homerun2-dev`) beside the
  cert-manager one.

---

## 8. The certificate chain

`*.homerun2-dev.sthings.lab` is issued by the lab's OpenBao PKI, not by a
self-signed CA. Three pieces, and they went in in this order:

| | |
|---|---|
| [`openbao/`](./openbao/) | the Kubernetes auth mount on the OpenBao — Terraform, run by a human |
| [`openbao-pki-ca.yaml`](./openbao-pki-ca.yaml) | the root CA cert-manager verifies OpenBao's TLS with |
| `cert-manager-vault-issuer` in [`infra-platform.yaml`](./infra-platform.yaml) | the `ClusterIssuer`, plus `CERT_MANAGER_SELFSIGNED_ISSUER: openbao-pki` |

The order is not a preference. Flux cannot create the auth mount — configuring
one needs an OpenBao token and this cluster's API address — so an issuer shipped
first is a `ClusterIssuer` that cannot log in. See [`openbao/README.md`](./openbao/README.md)
for the apply.

### ca-bundle here, ca-none on platform

`platform` selects the `ca-none` sub-component because its OpenBao runs in the
same cluster over plain HTTP: there is no certificate to verify, and reaching it
through the Gateway instead would be **circular** — that hostname's certificate
is issued by this very issuer.

Neither half of that applies here. OpenBao is on another cluster and reached at
`https://openbao.platform.sthings.lab`, so the issuer has to verify its TLS, and
there is no loop to avoid. Hence the default `ca-bundle` and
`VAULT_ISSUER_CA_SECRET: openbao-pki-ca`.

That CA is byte-identical to `clusters/platform/openbao-pki-ca.yaml` — same
OpenBao, same root. Verified rather than assumed: `sha256 f829dcf7835e47da53c8c2eb`
both in that file and from `https://openbao.platform.sthings.lab/v1/pki/ca/pem`.
A CA certificate is public, so neither copy is encrypted.

### Ready is not proof

cert-manager sets the issuer `Ready` on a successful Vault **login** and never
re-checks the ability to **sign**. A role bound to a policy that grants nothing
logs in perfectly and issues no certificate — the symptom appears at renewal,
months later. Only an issued Certificate is evidence:

```bash
export KUBECONFIG=~/.kube/homerun2-dev
kubectl get clusterissuer openbao-pki                      # Ready=True — necessary, not sufficient
kubectl -n default get certificate wildcard-tls -o wide    # this is the proof
kubectl -n default get certificate wildcard-tls -o jsonpath='{.status.conditions[*].message}'

curl -sk -v https://headlamp.homerun2-dev.sthings.lab/ 2>&1 | grep -E 'subject:|issuer:'
# issuer: CN=sthings.lab   <- OpenBao root, not CN=cluster-ca
```

- **The stack is ten components, listed in `homerun2.yaml`:** redis-stack,
  omni-pitcher, core-catcher, notification-catcher, scout, led-catcher,
  light-catcher, wled-mock, demo-pitcher, config-viewer -- see section 7. (This
  bullet used to say the last four were not carried; they were added in #227,
  #228, #229 and #233.)

---

## 9. The table tennis stack

[`tabletennis.yaml`](./tabletennis.yaml) runs **schmetterpause** (players, TTR,
tournaments, history) and **zaehlwerk** (the scoring API and its panel).
Credentials are in [`tabletennis-secrets.enc.yaml`](./tabletennis-secrets.enc.yaml);
the database is not in this directory at all, for a reason worth reading below.

### Assembled here rather than consumed from a profile

`apps/tabletennis/profiles/base` takes every credential from ExternalSecrets
against a `ClusterSecretStore`, and unlike `apps/homerun2` it ships no `sops/`
variant -- those patches sit in the *shared* `release.yaml` the production
tabletennis cluster runs. Splitting an `eso/` component out of a file in active
use is a bigger change than one cluster should force, so this file does what the
profile does minus ESO: the two OCIRepositories, the namespaces, upstream's
HTTPRoute/ConfigMap/Deployment patches copied verbatim, `$patch: delete` on the
three ExternalSecrets, and plain Secrets in their place.

The cost is honest: upstream changes to those patches do not reach us, so when
`apps/tabletennis` moves this file has to be re-read against it. **flux#483**
tracks giving it a real sops path; this cluster is the worked example.

Two `$patch: delete` entries are not tidiness. Without ESO the
`externalsecrets.external-secrets.io` CRD does not exist here at all, so leaving
those objects in fails the dry-run and takes the whole Kustomization with it.

### The database lives in a sibling directory

[`../homerun2-dev-seeds/schmetterpause-db.yaml`](../homerun2-dev-seeds/schmetterpause-db.yaml)
holds the CloudNativePG `Cluster`. `flux-system` applies `clusters/homerun2-dev`
recursively and a Kustomization fails as a whole, so a CNPG `Cluster` in *this*
directory is a deadlock rather than a race -- the CRD comes from `cnpg-operator`,
which `infra-platform` creates, which `flux-system` itself has to apply:

```
Cluster/schmetterpause/schmetterpause-db dry-run failed: no matches for kind
"Cluster" in version "postgresql.cnpg.io/v1"
```

That blocked every object in `clusters/homerun2-dev` on 2026-09-17, including
the one that installs the CRD. `prune: false`, because the PVC hangs off the
`Cluster` by ownerReference and CNPG has no retention of its own.

And one trap that cost a second outage: the `schmetterpause-db` Secret must also
carry **`SP_DATABASE_URL`**. Upstream's ExternalSecret does not copy that key, it
*synthesises* it in `target.template` -- replicate only `spec.data[]` and the app
comes up with a username, a password and no DSN.

### `tabletennis` is a stream nobody reads, and that is the decision

config-viewer reports it as an unread stream. The report is correct and the
configuration is deliberate.

zaehlwerk pitches scores through omni-pitcher, which routes `system: tabletennis`
onto a stream of that name (rule 3). zaehlwerk *can* then switch the led-catcher
onto that stream for the match and back to `messages` afterwards -- upstream
ADR-0003, with override tracking and a 20m idle timeout -- but only by calling
the catcher directly, which needs `CATCHER_URL`. **On this cluster zaehlwerk
reaches nothing but omni-pitcher**, so that variable is left unset and zaehlwerk
logs `panel stream switching disabled, no CATCHER_URL configured`. There is no
indirect path: omni-pitcher offers only `/pitch*` and has no catcher control, and
the led-catcher's switch is HTTP-only -- a message in a stream cannot trigger it.

So the switch is a human act. The led-catcher's web simulator carries it, and
[`homerun2.yaml`](./homerun2.yaml) sets `UI_STREAM_PRESETS=messages,tabletennis`
so the control actually offers both -- unset, it offers only the configured
stream and there is no way to reach `tabletennis` from the table. The header's
`overridden` badge and `reset` button are what stop a panel sitting on a dead
scoreboard after an abandoned match. From a terminal:

```bash
curl -s https://led-catcher.homerun2-dev.sthings.lab/streams
curl -s -X POST https://led-catcher.homerun2-dev.sthings.lab/streams \
  -H 'content-type: application/json' -d '{"streams": ["tabletennis"]}'
```

**That endpoint is unauthenticated.** Upstream calls it "fine while the port is
cluster-internal" -- which is not true here, because the shipped HTTPRoute
publishes it on the lab network. Accepted for now, knowingly: anyone who can
reach the hostname can take the panel over. Removing the HTTPRoute would also
remove the browser control that is currently the only way to switch.

---

## The predecessor, and why it is gone

`bootstrap-xplane` was the singlenode RKE2 VM this one replaces. It was retired
the same day `homerun2-dev` came up: `VirtualMachine`, `PersistentVolumeClaim`
and cloud-init `Secret` deleted on Harvester, the 50Gi Longhorn volume confirmed
released, and its files dropped from this repo.

It was already only a shell by then -- the VM ran, RKE2 did not answer -- and
the reason is worth keeping, because it is a trap this cluster shares. It was
built on `192.168.10.124`, came back from a rebuild on `.125`, and its committed
kubeconfig kept naming `.124`. The cluster read as gone (`no route to host`)
when only its address had moved. See step 3 above: the same DHCP lease applies
here.

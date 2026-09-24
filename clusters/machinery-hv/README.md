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
  pki.yaml                          -> ../machinery-hv-pki  (the OpenBao CA, after cert-manager)
  openbao/                          the cert-manager auth mount, as homerun2-dev
clusters/machinery-hv-fleet-state/  provider configs, EnvironmentConfigs, secrets
clusters/machinery-hv-xrs/          the ClusterStacks this cluster owns
clusters/machinery-hv-pki/          openbao-pki-ca, in cert-manager's namespace
vms/machinery-hv.*                  the VM shape and the RKE2 vars
```

The content directories sit **beside** this one, not in it: flux-system
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
   [Log: 3](#3-kubeconfig-off-the-node-2026-09-24), including the static DHCP
   lease `be:64:f3:26:1a:60` -> `192.168.10.105` (set on the router by hand,
   2026-09-24 -- `homerun2-dev` lost its etcd peer URL to a lease change,
   harvester#238).
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

Static lease on the router, set by hand in the DD-WRT UI on 2026-09-24 (the
workstation key is not accepted for ssh there, so this is the one step not
done from a shell): `BE:64:F3:26:1A:60` -> `192.168.10.105`, hostname
`machinery-hv`. Recorded in the lease table in `docs/install.md`.

### 4. Flux bootstrap (2026-09-24)

Synced to the PR branch, not `main` -- `--git-ref` is the bridge the
homerun2-dev runbook describes; `config.yaml` says how to take it back.

```bash
cd ~/harvester-machinery-hv
# GITHUB_USER, GITHUB_TOKEN, AGE_PUB, SOPS_AGE_KEY exported by ~/.bashrc
dagger call -m github.com/stuttgart-things/blueprints/flux@v3.2.2 \
  bootstrap \
  --kube-config file:///home/sthings/.kube/machinery-hv \
  --deploy-operator=true \
  --commit-to-git=true \
  --repository stuttgart-things/harvester \
  --branch-name feat/machinery-hv-scaffold \
  --git-ref refs/heads/feat/machinery-hv-scaffold \
  --destination-path "clusters/machinery-hv" \
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
# exit 0, Phase 0-8 all passed; the bot committed config.yaml + secrets.yaml
# (b36b1f1). The one `ERROR:` in the log is `helm plugin install helm-unittest`
# inside the helmfile container -- harmless, nothing depends on it.

git pull --rebase    # then the two detect-secrets pragmas into config.yaml, by hand
```

Two failures on the first reconcile, both visible only in the cluster:

```bash
export KUBECONFIG=~/.kube/machinery-hv
kubectl get kustomizations,gitrepositories -A
# kustomization/flux-system  False  Secret/cert-manager/openbao-pki-ca not found: namespaces "cert-manager" not found
# gitrepository/flux-system  False  lookup github.com on 10.43.0.10:53: server misbehaving
```

- **The CA deadlock -- a bug in this scaffold.** `openbao-pki-ca.yaml` sat in
  this directory, in a namespace only infra-platform creates, and flux-system
  applies this directory as one unit. Moved to `../machinery-hv-pki`, applied by
  [`pki.yaml`](./pki.yaml) with `dependsOn: cert-manager-install`.
- **DNS from the pod network is flaky, on both clusters.** CoreDNS forwards to
  the router and gets `read udp 10.42.0.x -> 192.168.10.1:53: i/o timeout`;
  the node itself resolves fine, and a test pod did too a minute later.
  homerun2-dev shows the same: 182 timeouts in its last 200 CoreDNS log lines.
  Not caused by this cluster; a forced reconcile got the source Ready:

```bash
kubectl -n kube-system logs -l k8s-app=kube-dns --tail=15          # the timeouts
kubectl run dnstest --rm -i --restart=Never --image=busybox:1.36 -- nslookup github.com 192.168.10.1
kubectl -n flux-system annotate gitrepository flux-system \
  reconcile.fluxcd.io/requestedAt="$(date +%s)" --overwrite
```

The DNS flakiness is tracked in stuttgart-things/harvester#252.

### 5. OpenBao auth mount for cert-manager (2026-09-24)

```bash
cd clusters/machinery-hv/openbao
export VAULT_TOKEN=$(tr -d '[:space:]' < ~/.vaulttoken)

KUBECONFIG_PATH=/home/sthings/.kube/machinery-hv ../../platform/openbao/preflight.sh
# cluster reachable ok / reviewer (exists=false, create=true) ok / openbao ok / VAULT_TOKEN accepted ok

# preflight does not check the policy the role binds -- and a missing one fails silently
curl -sk -H "X-Vault-Token: $VAULT_TOKEN" \
  https://openbao.platform.sthings.lab/v1/sys/policies/acl/pki-issue       # 200, pki/issue/* + pki/sign/*

terraform init
terraform plan -out=tfplan        # Plan: 8 to add, 0 to change, 0 to destroy
terraform apply tfplan            # Apply complete! Resources: 8 added
```

Checked rather than taken from the apply:

```bash
kubectl -n kube-system get sa vault-auth-reviewer                # exists
kubectl get clusterrolebinding kube-system-vault-auth-reviewer-auth-delegator \
  -o jsonpath='{.subjects[0].name}'                              # vault-auth-reviewer, NOT cert-manager
curl -sk -H "X-Vault-Token: $VAULT_TOKEN" \
  https://openbao.platform.sthings.lab/v1/auth/machinery-hv-certmanager/role/certmanager
# bound cert-manager/cert-manager, token_policies [pki-issue], ttl 3600
```

The ClusterIssuer had tried before the mount existed and sat on `403 permission
denied`; cert-manager backs off, so it was nudged:

```bash
export KUBECONFIG=~/.kube/machinery-hv
kubectl annotate clusterissuer openbao-pki resync="$(date +%s)" --overwrite
kubectl get clusterissuer openbao-pki                            # True, "Vault verified"
kubectl -n default get certificate wildcard-tls                  # True -- the proof, not the issuer
kubectl -n default get secret wildcard-tls -o jsonpath='{.data.tls\.crt}' | base64 -d \
  | openssl x509 -noout -subject -issuer
# subject=CN=*.machinery-hv.sthings.lab   issuer=C=DE, O=sva, CN=sthings.lab
curl -sk -o /dev/null -w '%{http_code} %{remote_ip}\n' https://headlamp.machinery-hv.sthings.lab/
# 200 192.168.10.178
```

One line, the whole chain: Clusterbook's wildcard, Cilium announcing `.178`, the
Gateway terminating with a certificate the OpenBao PKI signed.

### 6. Crossplane (2026-09-24)

All 19 Kustomizations Ready, including `cicd-platform`, `machinery-hv-fleet-state`
and `machinery-hv-xrs`:

```bash
kubectl get kustomizations -n flux-system
kubectl get pkg                                                  # 51 packages
kubectl get providers.pkg,configurations.pkg,functions.pkg \
  -o jsonpath='{range .items[*]}{.spec.package}{"\n"}{end}' | sed 's/:[^:]*$//' | sort | uniq -d
# (empty) -- no source under two CR names, the #506 failure mode
kubectl get xrd | wc -l                                          # 32 (+ header)
```

49 of 51 packages Healthy. The two that are not, and why:

```bash
kubectl get providerrevisions -l pkg.crossplane.io/package=stuttgart-things-provider-kubeconfig-xpkg \
  -o jsonpath='{.items[*].status.conditions[?(@.type=="RuntimeHealthy")].message}'
# cannot get referenced deployment runtime config: DeploymentRuntimeConfig "provider-kubeconfig" not found
# vshn-provider-minio: the same, for "provider-minio"
```

The profile points both providers at a runtime config it does not ship; on
LabDA the fleet state brings them (`provider-kubeconfig-vault` chart,
`provider-minio-runtime.yaml`). It does **not** block anything --
`crossplane-configs`' health check reads Configurations only -- but until the
two DRCs exist, provider-kubeconfig (every RemoteCluster, so every
ClusterStack) and provider-minio do not run. See
[the fleet-state README](../machinery-hv-fleet-state/README.md#provider-kubeconfig-watch-this-first).

### 7. Fleet state A-D (2026-09-24)

OpenBao side -- a Terraform root of its own, with every AppRole tested by a real
login; details and the permission table in
[`../platform/openbao/machinery-fleet/README.md`](../platform/openbao/machinery-fleet/README.md):

```bash
cd clusters/platform/openbao/machinery-fleet
export VAULT_TOKEN=$(tr -d '[:space:]' < ~/.vaulttoken)
terraform init -plugin-dir=../../../machinery-hv/openbao/.terraform/providers   # registry unreachable
terraform plan -out=tfplan        # 19 to add, 0 to change, 0 to destroy
terraform apply tfplan
./render-fleet-secrets.sh         # 10 Secrets, encrypted into machinery-hv-fleet-state/secrets
```

Cluster side, after the push:

```bash
export KUBECONFIG=~/.kube/machinery-hv
kubectl -n flux-system get kustomization machinery-hv-fleet-state      # True @ 69e2837
kubectl get appsecretprofiles                                          # 4 Ready
kubectl get clusterproviderconfigs.vault.m.upbound.io                  # vault, vault-cluster-secrets, vault-kubeconfig-writer
kubectl get environmentconfigs                                         # + cluster-vault-sthings-lab
```

The fleet-state Kustomization needed an explicit `spec.decryption` -- the
FluxInstance's patch reaches `flux-system` only (`kubectl get kustomization
<name> -o jsonpath='{.spec.decryption}'` was empty on every child).

The two provider-kubernetes configs, proven against the RIGHT cluster rather
than just "Ready": an Observe-only Object per config, reading `kube-system`,
compared by UID, then deleted (Observe never touches the target):

```bash
# Object probe-<pc>, managementPolicies [Observe], forProvider.manifest: Namespace kube-system
kubectl get objects.kubernetes.m.crossplane.io -n default probe-harvester \
  -o jsonpath='{.status.atProvider.manifest.metadata.uid}'    # 6cd45ed0-… = harvester's kube-system
# probe-rancher-mgmt                                          # 8acdc777-… = platform's kube-system
kubectl delete objects.kubernetes.m.crossplane.io -n default probe-harvester probe-rancher-mgmt
```

Open: `homerun2/_git-pat` is not seeded.

### 8. provider-kubeconfig and provider-minio (2026-09-24)

The two packages still unhealthy after step 6 both wait on a runtime config the
profile names and does not ship. First attempt: the `provider-kubeconfig-vault`
chart as on LabDA, against OpenBao, with a reader AppRole:

```bash
cd clusters/platform/openbao/machinery-fleet
./render-fleet-secrets.sh K       # crossplane-system/vault-approle (secret-id) + the roleIds values Secret
helm template pkv oci://ghcr.io/stuttgart-things/charts/provider-kubeconfig-vault --version 0.2.0 -f <values>
# 1 ClusterProviderConfig vault-kubeconfigs -> openbao, 1 CA, 1 DeploymentRuntimeConfig
```

It could not install -- on ANY fresh cluster, and so on LabDA's next rebuild too:

```
kubectl -n crossplane-system get helmrelease provider-kubeconfig-vault
# Helm install failed ... resource mapping not found for name: "vault-kubeconfigs" ...
# no matches for kind "ClusterProviderConfig" -- ensure CRDs are installed first
```

The release carries both the runtime config the provider needs to START and a
ClusterProviderConfig whose CRD the RUNNING provider registers. Split
(`../machinery-hv-fleet-state/provider-runtime.yaml`): the CA Secret and both
runtime configs as plain manifests; the chart keeps the ClusterProviderConfig
and RBAC, drops its copy of the config with a post-renderer (tested locally with
`helm template | kustomize build`), and retries install without limit.

```bash
export KUBECONFIG=~/.kube/machinery-hv
kubectl get providers.pkg.crossplane.io stuttgart-things-provider-kubeconfig-xpkg vshn-provider-minio   # both Healthy
# the release had exhausted its old retry budget before the fix landed -- forced once:
kubectl -n crossplane-system annotate helmrelease provider-kubeconfig-vault \
  reconcile.fluxcd.io/requestedAt="$(date +%s)" reconcile.fluxcd.io/forceAt="$(date +%s)" --overwrite
kubectl -n crossplane-system get helmrelease provider-kubeconfig-vault                  # Ready, install succeeded
kubectl get clusterproviderconfigs.kubeconfig.stuttgart-things.com                     # vault-kubeconfigs -> openbao
kubectl get pkg --no-headers | awk '$3!="True"' | wc -l                                # 0 -- 51/51 Healthy
```

Proven end to end, not by the config existing: a kubeconfig written with the
kubeconfig-WRITER AppRole, read back by a RemoteCluster through
`vault-kubeconfigs` (reader AppRole, OpenBao CA), then both removed:

```bash
# POST kubeconfigs/data/zz-probe {"kubeconfig": <machinery-hv's own kubeconfig>}   -> 200 (writer token)
# RemoteCluster zz-probe: providerConfigRef vault-kubeconfigs, source {type: vault, path: zz-probe, key: kubeconfig}
kubectl get remoteclusters.kubeconfig.stuttgart-things.com zz-probe
# Ready=True Available / Synced=True -- atProvider: rke2 v1.35.3+rke2r1, 1 node, apiEndpoint https://192.168.10.105:6443
kubectl delete remoteclusters.kubeconfig.stuttgart-things.com zz-probe
# DELETE kubeconfigs/metadata/zz-probe -> 204
```

### 9. flux v1.80.1 and coredns-lab-zone (2026-09-24)

flux#515 (`serve_stale` in both CoreDNS server blocks, default `24h`) merged as
v1.80.1, which differs from v1.80.0 only in that component. This cluster was
the first to take it: `git-repos.yaml` to `v1.80.1`, and `coredns-lab-zone`
selected in `infra-platform.yaml` with `COREDNS_ZONE: sthings.lab`,
`COREDNS_ZONE_SERVER: "192.168.10.1"`.

```bash
export KUBECONFIG=~/.kube/machinery-hv
kubectl -n kube-system rollout status deploy/rke2-coredns-rke2-coredns
# 0 of 1 updated replicas are available ... successfully rolled out -- ~47 s from Ready to rolled
kubectl -n kube-system get cm rke2-coredns-rke2-coredns -o jsonpath='{.data.Corefile}'
# sthings.lab.:53 { errors; cache 30 { serve_stale 24h }; forward . 192.168.10.1 }
# .:53 { ... forward . /etc/resolv.conf; cache 30 { serve_stale 24h } ... }

kubectl run dnsprobe2 --rm -i --restart=Never --image=busybox:1.36 -- sh -c 'nslookup <name>'
# github.com                             140.82.121.3
# ghcr.io                                140.82.121.33
# headlamp.machinery-hv.sthings.lab      192.168.10.178
# headlamp.homerun2-dev.sthings.lab      192.168.10.171
# kubernetes.default.svc.cluster.local   10.43.0.1

kubectl -n flux-system get kustomizations        # 20/20 Ready once the new tag had rippled through
kubectl get pkg                                  # 51/51 Healthy -- the profile did not change
```

### 10. `homerun2/_git-pat`, and `crossplane render` of app-dev-hv (2026-09-24)

The shared GitHub token, written straight to OpenBao rather than through
Terraform, so it does not also sit in a state file. Key `githubToken` -- the
property the homerun2 chart reads from that entry (`vaultProperty: githubToken`
in stuttgart-things/argocd `apps/homerun2/install/templates/secrets.yaml`):

```bash
export VAULT_TOKEN=$(tr -d '[:space:]' < ~/.vaulttoken)
python3 -c 'import json,os; print(json.dumps({"data":{"githubToken":open(os.path.expanduser("~/.githubtoken")).read().strip()}}))' \
  | curl -sk -H "X-Vault-Token: $VAULT_TOKEN" -X POST --data @- \
      https://openbao.platform.sthings.lab/v1/homerun2/data/_git-pat      # 200, version 1
# checked: key githubToken, 40 chars ghp_…, and api.github.com/user answers 200 with it
```

Render, against what is INSTALLED on this cluster -- the live Compositions,
the live Function packages, the live EnvironmentConfigs and AppSecretProfiles
as extra resources -- not against a checkout:

```bash
export KUBECONFIG=~/.kube/machinery-hv
kubectl get composition cluster -o yaml          > composition.yaml   # xplane-cluster 0.20.0
kubectl get functions.pkg.crossplane.io -o yaml  # -> functions.yaml, annotated
#   render.crossplane.io/runtime-docker-pull-policy: IfNotPresent, images pre-pulled:
#   crossplane render's own pull ran into its deadline on this uplink
kubectl get environmentconfigs,appsecretprofiles -o yaml > extra.yaml
crossplane render clusters/machinery-hv-xrs/app-dev-hv.yaml composition.yaml functions.yaml \
  --extra-resources extra.yaml --include-function-results
```

Four findings, in the order the render hit them:

1. **The order does not render as the mapping stands.** The `tabletennis`
   profile pulls schmetterpause, whose `-backup` entry reads the shared
   `object-store-backup`:
   `shared object-store-backup has no vault.shared entry in the EnvironmentConfig for environment 'sthings-lab'`.
   It needs a `vault.shared.object-store-backup` entry in
   `cluster-vault-sthings-lab` AND a seeded `schmetterpause/_backup` (S3
   credentials for CloudNativePG backups -- the MinIO on platform is the
   candidate). Added for the render only below, not on the cluster.
2. **The environment reaches the VM** -- the question this render was for. The
   VM is emitted once the RancherCluster publishes `status.nodeCommandSecret`
   (given as an observed resource), and
   `HarvesterVM.spec.environmentConfig: sthings-lab` -- straight from
   `ClusterStack.spec.environmentConfig` (xplane-cluster `logic.k`, `vmChild`).
   Rendered one level further through the live `harvester-vm` Composition:
   namespace `vms`, providerConfig `harvester`, image
   `default/sthings-u26-26.924.1008`, class `lh-fdd94630-…`, network
   `default/vms` -- all from `harvestervm-sthings-lab`.
3. **BLOCKER -- ansible cannot log in.** Rendered one level further again,
   through the `cloud-init` Composition, the VM boots with

   ```
   #cloud-config
   hostname: app-dev-hv
   ssh_pwauth: false
   disable_root: true
   ```

   -- no users, no `chpasswd`, password SSH OFF. The ansible stages log in with
   `tekton-ci/ansible-credentials`, a user and a PASSWORD. The ClusterStack
   passes only `vmName`/`hostname` into `HarvesterVM.spec.cloudInit`, the
   HarvesterVM XRD defaults `sshPasswordAuth: false`, and neither the order
   nor the EnvironmentConfig can set users or password auth. The bake path
   works because blueprints' `harvester-vm` module sets the cloud-init login
   itself. An upstream change in xplane-cluster / harvester-vm.
4. **`manage_filesystem+-true`** is hardcoded into the base-OS stage. On a
   single-root-disk VM that is the `'lvm_disk' is undefined` failure
   homerun2-dev and machinery-hv hit. `spec.ansible.extraVars` is appended
   AFTER it, so `manage_filesystem+-false` there is the likely override --
   unverified which one AnsibleRun lets win.

### 11. Back on main (2026-09-24)

#249 merged as f219d7a; `main` and `feat/machinery-hv-scaffold` were checked
identical for every machinery-hv path first
(`git diff --stat origin/main origin/feat/machinery-hv-scaffold -- clusters/machinery-hv* …` -> empty).
`config.yaml`'s `sync.ref` to `refs/heads/main` in its own PR, merged, THEN the
live instance -- the other order is undone by the next reconcile, because this
file is inside the synced path:

```bash
export KUBECONFIG=~/.kube/machinery-hv
kubectl -n flux-system patch fluxinstance flux --type=merge \
  -p '{"spec":{"sync":{"ref":"refs/heads/main"}}}'
kubectl -n flux-system get gitrepository flux-system -o jsonpath='{.spec.ref}{"  "}{.status.artifact.revision}'
```

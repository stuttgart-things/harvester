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

1. **Reserve the LB address** in Clusterbook -- done 2026-09-24, `.178`. By
   auto-assignment (`/reserve` without `ip`), as Clusterbook intends: the stale
   `ferdinand` (`.173`) and `martinwolf` (`.178`) records the homerun2-dev
   runbook warns about were already gone -- neither name resolved, even under a
   wildcard, and neither address had a PTR, while the three live clusters
   resolved correctly. Verified afterwards: ledger `178:ASSIGNED:DNS:machinery-hv`,
   `headlamp.machinery-hv.sthings.lab` -> `192.168.10.178`.
2. **Bake** with `vms/machinery-hv.params.enc.yaml` (the params plus the
   cloud-init credentials; `ANSIBLE_USER` / `ANSIBLE_PASSWORD` extracted from
   it, as in the homerun2-dev runbook): `bake-harvester --vm-name machinery-hv
   --inventory-type cluster` with the `--ansible-parameters` string from
   [`vms/README.md`](../../vms/README.md#machinery-hv).
3. **Fetch the kubeconfig** off the node, rewrite `127.0.0.1`, encrypt it to
   `secrets/machinery-hv.yaml`. Ask for a static DHCP lease for the VM's MAC --
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

# Claim Lifecycle

## Overview

Every resource ordered in this lab is a Crossplane XR in git. Git is the only
record of what exists: an order is a pull request that adds the XR, and the
cluster state follows from the merge. There is no separate registry or
inventory service.

> **History.** An earlier design tracked every claim in `claims/registry.yaml`,
> served by a `machinery-registry-api` and kept up to date by a
> `claim-status-collector`. None of the services was built, the file only ever
> held two CLI test claims, and the Backstage template *Delete Resource Claim*
> that depended on it never worked. All of it was removed on 2026-11-19
> (harvester#348).

## Where orders live

| Path | Cluster | Synced by | Prune | What |
|---|---|---|---|---|
| `clusters/crossplane-mgmt/xrs/` | crossplane-mgmt | Argo CD `showcase-crossplane-xrs` | on | `XVirtualMachine` and `AnsibleRun` claims |
| `clusters/machinery-hv/xrs/` | machinery-hv | Flux `machinery-hv-xrs` | **off**, plus `kustomize.toolkit.fluxcd.io/prune: disabled` on every XR | `ClusterStack` orders (Rancher cluster + platform layer), e.g. `app-dev-hv` |

## Create

1. A pull request adds the XR: from a Backstage template (`harvester-vm`,
   `create-xrs-pr` in stuttgart-things/backstage-resources), from
   `claims render` (see [claims CLI](../services/claims-cli.md)) or by hand.
   ClusterStack orders on machinery-hv are written by hand for now.
2. CI checks it (pre-commit; Kyverno policies for `clusters/crossplane-mgmt/xrs`).
3. On merge, Argo CD or Flux applies it and Crossplane composes the resources.
4. Backstage shows the result through the catalog entries of the repo.

The machinery-order-service (harvester#681) will take orders through an API
and portal and open these pull requests itself; until it runs, the paths above
are the only ones.

## Delete

**crossplane-mgmt (prune on):** revert the order PR, or open a PR that removes
the XR file. Argo CD prunes the XR and Crossplane deletes what it composed.
Tested in the demo: VM gone after 49 s.

**machinery-hv (prune off):** a revert alone does nothing, on purpose. Delete in
two phases (details in `clusters/machinery-hv/xrs/README.md`):

```bash
kubectl patch clusterstack <name> --type=merge -p '{"spec":{"platformEnabled":false}}'
kubectl delete clusterstack <name>
```

then remove the file in a PR, so Flux does not recreate it.

**Stuck deletion:** if a composed object cannot reach its target any more (the
target cluster is already gone), its finalizer holds the XR. Set that object to
`managementPolicies: ["Observe"]` so Crossplane releases it without a remote
delete, instead of removing finalizers by hand (harvester#601).

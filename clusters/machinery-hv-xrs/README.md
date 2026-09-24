# `machinery-hv` — stable XRs

The orders this cluster owns: the clusters it builds. Applied by the
`machinery-hv-xrs` Kustomization in [`../machinery-hv/xrs.yaml`](../machinery-hv/xrs.yaml).
The same four rules as the LabDA machinery cluster
([stuttgart-things `machinery-xrs/README.md`](https://github.com/stuttgart-things/stuttgart-things/blob/main/clusters/labda/vsphere/machinery-xrs/README.md)):

1. **`prune: false` on the Kustomization.** Deleting a file must never be what
   tears down a cluster.
2. **`kustomize.toolkit.fluxcd.io/prune: disabled` on every XR**, in case anyone
   flips rule 1.
3. **`stuttgart-things.com/management-cluster: machinery-hv` on every XR**, so the
   object says which cluster reconciles it. An XR applied to crossplane-mgmt
   instead does nothing there -- that cluster has no `ClusterStack` XRD.
4. **Only `spec` and `metadata` in git**, never what Crossplane writes back.

## Deleting an XR

```bash
# 1. a ClusterStack: turn the platform off and let it settle first --
#    the stack-uses-platform Usage blocks a direct delete
kubectl patch clusterstack <name> --type=merge -p '{"spec":{"platformEnabled":false}}'
kubectl delete clusterstack <name>

# 2. only once the object is really gone:
git rm clusters/machinery-hv-xrs/<name>.yaml   # and drop it from kustomization.yaml
```

## Moving an order here from crossplane-mgmt

`tabletennis` is a `RancherCluster` on crossplane-mgmt, not a `ClusterStack`, so
there is nothing to move: it is rebuilt here as a new order and the old one
retired afterwards. Never run both at once -- the two name the same VM, the same
address, the same OpenBao mounts and the same Argo CD registration.

## What is here

| File | Listed | |
|---|---|---|
| `app-dev-hv.yaml` | **no** | the first order, drafted; blockers in its header |

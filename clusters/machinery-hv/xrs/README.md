# `machinery-hv` — stable XRs

The orders this cluster owns: the clusters it builds. Applied by the
`machinery-hv-xrs` Kustomization in [`../xrs.yaml`](../xrs.yaml).
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
5. **A NEW order sets `spec.rancher.clusterAnnotations:
   {field.cattle.io/no-creator-rbac: "true"}`.** `rancher-mgmt` is the scoped
   ServiceAccount `crossplane-machinery` since 2026-09-28. Without the
   annotation Rancher stamps it as the cluster's creator and gives it
   cluster-owner on every cluster it builds, which undoes the scoping. It is
   honoured at CREATE only: never add it to an existing order -- the webhook
   refuses it next to a creatorId, and the Object would re-apply it for ever.
   `app-dev-hv` was created with the admin credential and keeps it
   (`creatorId: system:admin`). The machine pool's HarvesterConfig cannot carry
   the annotation yet (rancher-cluster v0.11.0 sets it on the Cluster only), so
   the ServiceAccount becomes that HarvesterConfig's creator -- limited to that
   one object.

## Deleting an XR

```bash
# 1. a ClusterStack: turn the platform off and let it settle first --
#    the stack-uses-platform Usage blocks a direct delete
kubectl patch clusterstack <name> --type=merge -p '{"spec":{"platformEnabled":false}}'
kubectl delete clusterstack <name>

# 2. only once the object is really gone:
git rm clusters/machinery-hv/xrs/<name>.yaml   # and drop it from kustomization.yaml
```

## Moving an order here from crossplane-mgmt

`tabletennis` is a `RancherCluster` on crossplane-mgmt, not a `ClusterStack`, so
there is nothing to move: it is rebuilt here as a new order and the old one
retired afterwards. Never run both at once -- the two name the same VM, the same
address, the same OpenBao mounts and the same Argo CD registration.

## What is here

| File | Listed | |
|---|---|---|
| `app-dev-hv.yaml` | yes | the first order (2026-09-28), admin credential as creator; homerun2 + tabletennis |
| `app-dev-hv-backup.yaml` | yes | app-dev-hv's CNPG backup bucket |

## Build log: demo-hv (2026-09-30, harvester#309 block 4)

The first order with the scoped identity `crossplane-machinery` and
`no-creator-rbac`. Times are UTC.

```bash
# 07:11:46 -- #311 merged
export KUBECONFIG=~/.kube/machinery-hv
flux reconcile ks machinery-hv-xrs -n flux-system --with-source   # applied 1475260
kubectl get clusterstack demo-hv -o wide                          # node-ip -> kubeconfig at 07:11:59
crossplane resource trace clusterstack demo-hv -n default         # `beta trace` is gone in CLI v2.4.1
```

**Stop 1: the Rancher webhook refused the Cluster** (07:11:59):
`admission webhook "rancher.cattle.io.clusters.provisioning.cattle.io" denied the request: Unauthorized`.
Webhook v0.10.6 `validateCloudCredentialAccess` needs `get` on the cloud
credential Secret, and the scoped identity lacked it:

```bash
export KUBECONFIG=~/.kube/platform.sthings.lab
kubectl auth can-i get secret/cc-cl944 -n cattle-global-data \
  --as=system:serviceaccount:crossplane-machinery:crossplane-machinery   # no
```

Fixed by #325 (Role on that one Secret). After it merged (07:16:09):

```bash
flux reconcile ks flux-system -n flux-system --with-source   # on platform
kubectl auth can-i get secret/cc-cl944 -n cattle-global-data --as=...   # yes, 07:16:20
```

The Object retried by itself. The Rancher Cluster was created at ~07:16:57,
**without a `creatorId`** (`no-creator-rbac=true`), so the identity is not
cluster-owner of what it builds. The VM was Running at 07:17:20 (192.168.10.172).
Stages: `access` at 07:25:24, `platform` at 07:26:55.

**Stop 2: clusterbook had no free IP** for the gateway/DNS reservation (the
pool of 8 was full; the node took the last one): `reserve request returned
status 409: {"error":"no available IPs in network"}`. The Argo CD cluster
secret, and with it every platform app, waits on that. The pool was extended in
the live CR (see `../../platform-seeds/networkconfig-networks-labul.yaml`):

```bash
export KUBECONFIG=~/.kube/platform.sthings.lab
curl -sk https://clusterbook.platform.sthings.lab/api/v1/networks   # Total 8, Available 0
kubectl -n clusterbook patch networkconfig networks-labul --type json -p \
  '[{"op":"add","path":"/spec/networks/192.168.10/-","value":"174"},
    {"op":"add","path":"/spec/networks/192.168.10/-","value":"175"}]'   # 07:59:45
kubectl annotate clusterbookcluster demo-hv \
  reconcile.clusterbook/requested-at="$(date -u +%FT%TZ)" --overwrite   # skip the operator's backoff
kubectl get clusterbookcluster demo-hv   # 08:00:15: 192.168.10.175, *.demo-hv.sthings.lab, cluster-demo-hv
```

(The lab was moved to another room between 07:40 and 07:53. demo-hv survived
it at stage `platform`; Backstage did not come up by itself: it started before
the network and hung on `connect EPERM` to Postgres, so it needed
`kubectl -n backstage rollout restart deploy/backstage-deployment`.)

**Stop 3: no network apps.** After the IP, Argo CD had the security and storage
apps but no cert-manager/cilium/trust-manager, and the `platform` stage waits on
`Endpoints cert-manager/cert-manager-webhook`. stuttgart-things/argocd#566 (the
same morning) gates the network AppSets on
`clusterbook.stuttgart-things.com/cluster-ready=true`, which only
clusterbook-operator v0.21.0 stamps; platform ran v0.20.0, so the network AppSets
matched **no** cluster (app-dev-hv's cert-manager app had silently gone too).
Fixed by #332 (08:23:46):

```bash
export KUBECONFIG=~/.kube/platform.sthings.lab
flux reconcile ks flux-system -n flux-system --with-source
flux reconcile ks argocd-platform -n flux-system --with-source
flux reconcile ks argocd-platform-clusterbook-operator -n flux-system
kubectl -n argocd get secret -l argocd.argoproj.io/secret-type=cluster -o json \
  | jq -r '.items[]|(.data.name|@base64d)+" "+(.metadata.labels["clusterbook.stuttgart-things.com/cluster-ready"]//"-")'
# all four clusters: true; network apps back on every cluster
```

**`ready` at 08:26:14.** Without the three stops, rancher -> ready is roughly
15-20 min (VM at +0.5 min, `access` at +8.5 min, `platform` at +10 min).

# Harvester cluster -- objects applied by hand

Nothing here is synced by Flux. These are objects that belong on the Harvester
cluster itself and are applied with `kubectl --kubeconfig ~/.kube/harvester`.

| File | For | Applied |
|---|---|---|
| `backstage-vm-reader.yaml` | read-only ServiceAccount + token for the Backstage VM entity provider on `platform.sthings.lab` | `kubectl --kubeconfig ~/.kube/harvester apply -f clusters/harvester/backstage-vm-reader.yaml` |
| `homerun2-schedule-pitcher-reader.yaml` | read-only ServiceAccount + token (get/list `volumes.longhorn.io`) for the schedule-pitcher agent on homerun2-dev, which checks that every Longhorn volume is healthy (#573) | `kubectl --kubeconfig ~/.kube/harvester apply -f clusters/harvester/homerun2-schedule-pitcher-reader.yaml` |
| `storageclass-longhorn-single.yaml` | default StorageClass with 1 Longhorn replica (single node, #573); `harvester-longhorn` (chart-managed, 3 replicas) is no longer default | annotate `harvester-longhorn` `is-default-class=false` first, then `kubectl --kubeconfig ~/.kube/harvester apply -f clusters/harvester/storageclass-longhorn-single.yaml` (see the file) |

# Crossplane observability

Monitoring for the clusters that run Crossplane, on top of their own
kube-prometheus-stack in `monitoring` (harvester#753). One directory, applied
unchanged to:

| Cluster | Applied by | Stack from |
|---|---|---|
| crossplane-mgmt | Argo CD Application `crossplane-mgmt-crossplane-observability` on platform ([`../../platform/clusters/platform-crossplane-showcase-apps.yaml`](../../platform/clusters/platform-crossplane-showcase-apps.yaml)) | argocd `platforms/observability` |
| machinery-hv | Flux Kustomization `crossplane-observability` ([`../../machinery-hv/crossplane-observability.yaml`](../../machinery-hv/crossplane-observability.yaml)) | flux `infra/kube-prometheus-stack` |

Neither is part of the Crossplane layers (`showcase-crossplane-platform`,
`machinery-hv-fleet-state`), so a missing monitoring CRD stalls only this.

## What is in here

| File | What |
|---|---|
| `podmonitors.yaml` | Scraping of Crossplane core + rbac-manager (`:8080`), every provider (port `metrics`, label `provider`), every function except function-auto-ready (port `metrics`, label `function`) |
| `crossplane-state-metrics.yaml` + `-config.yaml` | A second kube-state-metrics (custom resource state only): Ready/Synced and lastTransitionTime of every XR and composed MR as `crossplane_xr_*` / `crossplane_mr_*` |
| `prometheusrule.yaml` | `CrossplaneXRNotReady` (warning, Ready != True for 30m), `CrossplaneStateMetricsDown` |
| `dashboards/` | Grafana folder **Crossplane**: *Crossplane Metrics* (community), *Crossplane XR Status* (ours) |

Nothing scraped Crossplane before (2026-11-19). The stacks select monitors and
rules in every namespace without a label (`*SelectorNilUsesHelmValues: false`),
so nothing here needs a `release` label.

## XR status metrics

Crossplane itself exports nothing per XR: core has controller-runtime counters
per XRD controller, providers count managed resources per GVK
(`crossplane_managed_resource_{exists,ready,synced}`). Per object, from
crossplane-state-metrics:

| Series | Labels (besides `customresource_group/kind/version`, `namespace`, `name`, `composite`) |
|---|---|
| `crossplane_xr_status_condition` | `type`, `reason`; 1 = True, 0 = False/Unknown |
| `crossplane_xr_status_condition_last_transition_time` | `type`; unix seconds |
| `crossplane_xr_created` | unix seconds |
| `crossplane_xr_info` | `composition`, `composition_revision` |
| `crossplane_xr_resource_ref` | `ref_api_version`, `ref_kind`, `ref_name` (one per composed resource) |
| `crossplane_mr_status_condition`, `crossplane_mr_status_condition_last_transition_time` | as for XRs |

`composite` is the label `crossplane.io/composite`: the top-level XR an object
belongs to (an XR's own name for a top-level one).

Example: XRs not Ready, with the time since Ready last changed:

```promql
(time() - crossplane_xr_status_condition_last_transition_time{type="Ready"})
  and on (customresource_kind, namespace, name)
  (crossplane_xr_status_condition{type="Ready"} == 0)
```

### Adding a kind

- **New XRD in a group already listed** (`resources`, `config`, `secrets`,
  `storage`, `vault` `.stuttgart-things.com`): nothing to do, the groups are
  watched with `kind: "*"`.
- **New XR group**: one entry `- <<: *xr` with the group in
  `crossplane-state-metrics-config.yaml`, AND the group in the ClusterRole in
  `crossplane-state-metrics.yaml`.
- **New MR kind**: the same with `- <<: *mr`. Pin the kind when the group also
  holds ProviderConfigs; avoid `kind: "*"` on groups with dozens of kinds
  (every kind is an informer).

A group missing in the ClusterRole shows as `forbidden` in the pod's log and
an empty kind, not as an error anywhere else. Check after a change:

```bash
kubectl -n monitoring logs deploy/crossplane-state-metrics | grep -iE 'forbidden|error'
```

Before pushing, the config can be tried read-only from the workstation (the
image lists and watches with your kubeconfig, nothing else):

```bash
docker run --rm --network host -v ~/.kube:/kube:ro -v $PWD:/cfg:ro \
  registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.20.0 \
  --kubeconfig=/kube/machinery-hv --custom-resource-state-only \
  --custom-resource-state-config-file=/cfg/crossplane-state-metrics-config.yaml \
  --port=18080 --telemetry-port=18081
curl -s localhost:18080/metrics | grep '^crossplane_xr_status_condition{'
```

## Dashboards

Grafana loads them from the ConfigMaps (label `grafana_dashboard: "1"`), no
download at start. Folder by the annotation `grafana_folder: Crossplane`,
which needs the sidecar's `folderAnnotation` (+ `foldersFromFilesStructure`):
set in `../../machinery-hv/kube-prometheus-stack.yaml`; on crossplane-mgmt it
comes with the argocd catalog's kube-prometheus-stack chart (until then the
two land in General).

- **`crossplane-xr-status.json`** — ours, generated for these metrics. XR and
  MR counts, a table of every XR/MR condition that is not True with reason and
  *since*, all XRs (Ready, Synced, composed resources, Composition), XRs per
  kind, not-ready XRs per kind over time, Ready over time per XR, MRs of a
  top-level XR, provider counters per GVK, reconcile errors and p95 per
  provider, reconcile errors per XRD, non-Normal function results. Variables:
  XR kind, top-level XR.
- **`crossplane-metrics.json`** — grafana.com
  [24549](https://grafana.com/grafana/dashboards/24549) "Crossplane Metrics",
  revision 3 (2025-12-15, the only Crossplane dashboard on grafana.com, built
  on docs.crossplane.io/latest/guides/metrics). One edit: the `resolution`
  variable without 15s/30s/1m -- with the 60s scrape interval a `rate()` over
  less than two scrapes is empty. Its panels are unfiltered, so they show core,
  rbac-manager and every provider together. *Circuit Breaker Events* reads
  `circuit_breaker_{opens,closes}_total`, which Crossplane only exports after
  a breaker has opened once: no data there is the normal state.

Updating the community one: download the revision, re-apply the edit:

```bash
curl -sL https://grafana.com/api/dashboards/24549/revisions/<rev>/download | jq '
  (.templating.list[] | select(.name == "resolution")) |=
    (.options |= map(select(.value | IN("3m", "5m", "10m"))) | .query = "3m, 5m, 10m")
' > dashboards/crossplane-metrics.json
```

Panel queries were checked against the metrics both clusters actually serve
(2026-11-19, Crossplane v2.4.2/v2.4.3) before this went in.

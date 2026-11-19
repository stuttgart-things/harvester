# Architecture Overview

## How resources are ordered

Everything is a Crossplane XR in git; Git is the shared state and the audit
trail. No service keeps its own record of what exists.

```
   Backstage templates      claims CLI           hand-written PR
   (harvester-vm,           (claims render)
    create-xrs-pr)               │
          │                      │ renders through
          │                      ▼
          │              claim-machinery-api (KCL templates)
          │                      │
          └──────────┬───────────┘
                     ▼
         Pull request in stuttgart-things/harvester
                     │ merge
        ┌────────────┴─────────────┐
        ▼                          ▼
  clusters/crossplane-mgmt/xrs   clusters/machinery-hv/xrs
  Argo CD, prune on              Flux, prune off
  XVirtualMachine, AnsibleRun    ClusterStack
        │                          │
        ▼                          ▼
  Crossplane on crossplane-mgmt  Crossplane on machinery-hv
        │                          │
        └────────────┬─────────────┘
                     ▼
        Harvester VMs, Rancher clusters, platform layer
```

Create and delete are described in [Claim Lifecycle](claim-lifecycle.md).

## Design principles

### Git as source of truth

All state lives in Git. This means:

- a full audit trail through git history;
- GitOps-native: Argo CD and Flux reconcile the cluster state from git;
- PRs provide review and approval for every change.

### Backstage independence

Backstage is a UI layer, not a requirement. Every order can also be made with
the claims CLI or a hand-written PR, so CI/CD and the terminal work without it.

## Components

| Component | Responsibility | Where |
|---|---|---|
| claim-machinery-api | Renders KCL claim templates | machinery-hv (with ZITADEL auth, #706) |
| claims CLI | Renders claims and opens the PR | workstation / CI |
| Backstage | Self-service templates, catalog | platform |
| machinery-order-service | Planned: takes orders via API/portal and opens the PR (harvester#681) | platform |

The earlier registry design (`claims/registry.yaml`, claim-registry API,
claim-status-collector) was never built and was removed on 2026-11-19
(harvester#348).

# Architecture Overview

## System Architecture

The claim-machinery platform consists of independent microservices that collaborate through Git as the shared state layer.

```
                    ┌──────────────┐
                    │  Backstage   │
                    │  (Portal UI) │
                    └──────┬───────┘
                           │ uses
              ┌────────────┼────────────────┐
              │            │                │
              ▼            ▼                ▼
      ┌──────────────┐ ┌────────────┐ ┌─────────────────┐
      │  claim-       │ │  claim-    │ │  claim-status   │
      │  machinery-   │ │  registry  │ │  collector      │
      │  api          │ │  API       │ │                 │
      │               │ │            │ │  polls cluster  │
      │  renders KCL  │ │  serves    │ │  for claim      │
      │  templates    │ │  registry  │ │  health/status  │
      └──────────────┘ │  .yaml     │ └────────┬────────┘
                       └──────┬─────┘          │
              ┌──────────────┐│                │
              │  claims CLI  ││ reads          │ updates
              │              ││                │
              │  • render    │▼                ▼
              │  • delete    ├──────────────────────────┐
              │  • list      │  Git (harvester repo)    │
              │              │                          │
              │  writes to   │  claims/registry.yaml    │
              │  git + PR ──►│  claims/{cat}/{name}/    │
              └──────────────┘  catalog-info.yaml       │
                               └────────────────────────┘
```

## Design Principles

### Git as Source of Truth

All state lives in Git. No service maintains its own persistent database. This means:

- Full audit trail through git history
- GitOps-native: Flux reconciles the actual cluster state from git
- Any service can be rebuilt or replaced without data loss
- PRs provide review and approval workflows for all changes

### Backstage Independence

Every operation that can be done through Backstage can also be done through the CLI or API directly. Backstage is a UI layer, not a requirement. This ensures:

- CI/CD pipelines can create and delete claims without Backstage
- Developers can work from their terminal
- Automated cleanup (TTL, policy-based) doesn't depend on Backstage availability

### Microservice Separation

Each service has a single responsibility:

| Service | Responsibility | Stateful? |
|---------|---------------|-----------|
| claim-machinery-api | Template rendering (KCL) | No (templates loaded at startup) |
| claims CLI | Git operations (create/delete/PR) | No (git is the state) |
| claim-registry API | Serve claim inventory | No (reads from git) |
| claim-status-collector | Monitor cluster health | No (writes to git) |

## Data Flow

### Create Flow

```
User/Backstage
    │
    ▼
claims CLI (render)
    │
    ├──► claim-machinery-api (render template)
    │         │
    │         ▼
    │    KCL engine + OCI registry
    │         │
    │         ▼
    │    rendered YAML
    │
    ├──► write files to git branch
    │    ├── claims/{cat}/{name}/{template}.yaml
    │    ├── claims/{cat}/{name}/kustomization.yaml
    │    ├── claims/{cat}/{name}/catalog-info.yaml
    │    └── claims/registry.yaml (add entry)
    │
    ├──► update claims/{cat}/kustomization.yaml
    │
    └──► create PR
```

### Delete Flow

```
User/Backstage/Automation
    │
    ▼
claims CLI (delete)
    │
    ├──► claim-registry API (resolve claim metadata)
    │
    ├──► remove files from git branch
    │    ├── claims/{cat}/{name}/ (entire directory)
    │    └── claims/registry.yaml (remove entry)
    │
    ├──► update claims/{cat}/kustomization.yaml
    │
    └──► create PR
```

### Status Flow

```
claim-status-collector (periodic)
    │
    ├──► query Kubernetes API for Crossplane claim status
    │    (Ready, Synced, conditions, errors)
    │
    ├──► update claims/registry.yaml (status fields)
    │
    └──► optionally update Backstage catalog annotations
         via Backstage API
```

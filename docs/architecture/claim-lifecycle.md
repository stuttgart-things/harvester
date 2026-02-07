# Claim Lifecycle

## Overview

Every Crossplane claim managed through the platform follows a defined lifecycle from creation to deletion. All state transitions are tracked in `claims/registry.yaml` and executed through Git pull requests.

## Lifecycle States

```
  ┌──────────┐     PR merged      ┌──────────┐
  │ creating ├────────────────────►│  active   │
  └──────────┘                    └─────┬─────┘
                                        │
                              ┌─────────┼─────────┐
                              │         │         │
                              ▼         ▼         ▼
                         ┌────────┐ ┌───────┐ ┌────────┐
                         │healthy │ │ error │ │unknown │
                         └────────┘ └───────┘ └────────┘
                              │         │         │
                              └─────────┼─────────┘
                                        │
                              delete PR merged
                                        │
                                        ▼
                                  ┌──────────┐
                                  │ deleted  │
                                  └──────────┘
```

## File Artifacts Per Claim

When a claim is created, three files are generated in `claims/{category}/{name}/`:

### 1. Claim Manifest (`{template}.yaml`)

The rendered Crossplane claim resource:

```yaml
apiVersion: sthings.io/v1alpha1
kind: VolumeClaim
metadata:
  name: app-pvc
  namespace: default
spec:
  storage: 10Gi
  storageClassName: nfs4-csi
```

### 2. Kustomization (`kustomization.yaml`)

Local kustomization referencing the claim manifest:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - volumeclaim.yaml
```

### 3. Catalog Info (`catalog-info.yaml`)

Backstage component registration:

```yaml
apiVersion: backstage.io/v1alpha1
kind: Component
metadata:
  name: app-pvc
  description: Crossplane claim (volumeclaim) - app-pvc
  annotations:
    github.com/project-slug: stuttgart-things/harvester
    claim-machinery/template: volumeclaim
    claim-machinery/category: infra
  tags:
    - crossplane
    - claim
    - volumeclaim
    - infra
spec:
  type: crossplane-claim
  lifecycle: production
  owner: platform-team
```

## Parent Kustomization

Each category directory has a `kustomization.yaml` that references its children:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - app-pvc
  - my-database
```

This file is updated on both create (add entry) and delete (remove entry).

## Create Workflow

1. User selects a template and provides parameters (via CLI or Backstage)
2. `claims` CLI calls `claim-machinery-api` to render the template
3. CLI writes the three artifact files to a new git branch
4. CLI adds an entry to `claims/registry.yaml`
5. CLI updates the parent `kustomization.yaml`
6. CLI creates a pull request
7. On PR merge, Flux reconciles the claim to the cluster

## Delete Workflow

1. User selects a claim to delete (via CLI, Backstage, or automation)
2. `claims` CLI resolves claim metadata (from registry or API)
3. CLI removes the entire `claims/{category}/{name}/` directory on a new branch
4. CLI removes the entry from `claims/registry.yaml`
5. CLI removes the entry from parent `kustomization.yaml`
6. CLI creates a pull request
7. On PR merge, Flux removes the claim from the cluster

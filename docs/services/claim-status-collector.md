# Claim Status Collector

**Repository:** `stuttgart-things/claim-status-collector` (to be created)

## Overview

The claim-status-collector is a service that periodically checks the actual state of deployed Crossplane claims in the cluster and updates the registry and Backstage catalog with health information.

## What It Does

1. Reads `claims/registry.yaml` to get the list of claims to monitor
2. Queries the Kubernetes API for each claim's Crossplane status (Ready, Synced, conditions)
3. Updates `claims/registry.yaml` with current status fields
4. Optionally updates Backstage catalog annotations for richer dashboard information

## Status Fields Updated

```yaml
claims:
  - name: app-pvc
    # ... existing fields ...
    status: active          # active | error | unknown | deleting
    statusMessage: "Ready: True, Synced: True"
    lastCheckedAt: "2025-07-15T12:00:00Z"
```

## Deployment Modes

### In-Cluster (recommended)

Runs as a CronJob or Deployment inside the Kubernetes cluster where claims are deployed:

- Direct access to Kubernetes API (ServiceAccount RBAC)
- Can read Crossplane claim status natively
- Commits status updates to git

### External

Runs outside the cluster with a kubeconfig:

- Useful for multi-cluster monitoring
- Requires kubeconfig or service account token

## Configuration

| Env Var | Default | Description |
|---------|---------|-------------|
| `REGISTRY_REPO` | - | GitHub repository slug |
| `REGISTRY_PATH` | `claims/registry.yaml` | Path to registry file |
| `CHECK_INTERVAL` | `5m` | Status check interval |
| `KUBECONFIG` | in-cluster | Path to kubeconfig (external mode) |
| `GITHUB_TOKEN` | - | Token for git operations |
| `BACKSTAGE_URL` | - | Backstage API URL (optional, for catalog updates) |

## Roadmap

This is a **Phase 3** component. Implementation priority:

1. Basic status checking (Ready/Synced conditions)
2. Registry updates via git commit
3. Backstage catalog annotation updates
4. Multi-cluster support
5. Alerting integration (webhook on status change)

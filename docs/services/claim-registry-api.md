# Claim Registry API

**Repository:** `stuttgart-things/claim-registry` (to be created)

## Overview

The claim-registry API is a lightweight service that serves the claim inventory from `claims/registry.yaml` in the harvester repository. It provides a REST interface for querying existing claims, consumed by Backstage, the claims CLI, and other automation.

## API Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/v1/claims` | GET | List all claims |
| `/api/v1/claims/{name}` | GET | Get claim details by name |
| `/health` | GET | Health check |
| `/version` | GET | Build version metadata |

### Query Parameters

`GET /api/v1/claims` supports filtering:

| Parameter | Example | Description |
|-----------|---------|-------------|
| `category` | `?category=infra` | Filter by category |
| `template` | `?template=volumeclaim` | Filter by template type |
| `status` | `?status=active` | Filter by status |
| `source` | `?source=backstage` | Filter by creation source |

### Response Format

```json
{
  "apiVersion": "claim-registry.io/v1alpha1",
  "kind": "ClaimList",
  "items": [
    {
      "name": "app-pvc",
      "template": "volumeclaim",
      "category": "infra",
      "namespace": "default",
      "createdAt": "2025-06-15T10:00:00Z",
      "createdBy": "patrick",
      "source": "backstage",
      "repository": "stuttgart-things/harvester",
      "path": "claims/infra/app-pvc",
      "status": "active"
    }
  ]
}
```

## Architecture

```
┌────────────────────────────┐
│  claim-registry API        │
│                            │
│  ┌──────────────────────┐  │
│  │ Git Sync             │  │     ┌──────────────────┐
│  │ (poll or webhook)    │◄─┼─────│ harvester repo   │
│  │                      │  │     │ registry.yaml    │
│  └──────────┬───────────┘  │     └──────────────────┘
│             │              │
│  ┌──────────▼───────────┐  │
│  │ In-memory cache      │  │
│  │ (parsed registry)    │  │
│  └──────────┬───────────┘  │
│             │              │
│  ┌──────────▼───────────┐  │
│  │ HTTP Handlers        │  │
│  │ GET /api/v1/claims   │  │
│  └──────────────────────┘  │
└────────────────────────────┘
```

## Tech Stack

Follows the same patterns as `claim-machinery-api`:

- **Language:** Go
- **Router:** Gorilla Mux
- **Config:** Cobra + environment variables
- **Git access:** HTTP raw file fetch or `go-git` clone

## Configuration

| Env Var | Default | Description |
|---------|---------|-------------|
| `REGISTRY_REPO` | - | GitHub repository slug (e.g., `stuttgart-things/harvester`) |
| `REGISTRY_PATH` | `claims/registry.yaml` | Path to registry file in repo |
| `REGISTRY_BRANCH` | `main` | Git branch to read from |
| `SYNC_INTERVAL` | `60s` | Polling interval for registry updates |
| `PORT` | `8080` | HTTP server port |
| `GITHUB_TOKEN` | - | Token for accessing private repos |

# Claim Registry

## Purpose

The claim registry is a structured YAML file (`claims/registry.yaml`) that serves as the single source of truth for all claims managed through the platform. It replaces the previous approach of discovering claims solely through filesystem scanning or Backstage catalog discovery.

## Why a Registry?

Without a centralized registry:

- Only Backstage knows what claims exist (by scanning `catalog-info.yaml` files)
- The CLI has no way to list or resolve claims without scanning the repo
- Automated tooling (cleanup, status checks) must walk the directory tree
- No structured metadata beyond what's in individual `catalog-info.yaml` files

With a registry:

- Any service can query what claims exist by reading one file
- The `claim-registry` API serves this data over HTTP
- Delete operations can resolve claim paths and metadata instantly
- Status information has a centralized place to live

## Schema

The registry file lives at `claims/registry.yaml`:

```yaml
---
apiVersion: claim-registry.io/v1alpha1
kind: ClaimRegistry
claims:
  - name: app-pvc
    template: volumeclaim
    category: infra
    namespace: default
    createdAt: "2026-02-04T19:43:28Z"
    createdBy: patrick
    source: backstage
    repository: stuttgart-things/harvester
    path: claims/infra/app-pvc
    status: active
  - name: abrechnungen
    template: volumeclaim
    category: other-resources
    namespace: default
    createdAt: "2026-02-05T17:45:56Z"
    createdBy: patrick
    source: backstage
    repository: stuttgart-things/harvester
    path: claims/other-resources/abrechnungen
    status: active
```

## Field Reference

| Field | Required | Description |
|-------|----------|-------------|
| `name` | yes | Unique claim name (matches directory name) |
| `template` | yes | Claim template used (e.g., `volumeclaim`, `postgresql`) |
| `category` | yes | Category directory (`infra`, `apps`, `other-resources`, `cli`) |
| `namespace` | no | Kubernetes namespace for the claim |
| `createdAt` | yes | ISO 8601 timestamp of creation |
| `createdBy` | yes | User or service that created the claim |
| `source` | yes | Origin of creation: `backstage`, `cli`, or `ci` |
| `repository` | yes | Git repository slug |
| `path` | yes | Path within the repository |
| `status` | no | Current status (`active`, `error`, `unknown`). Updated by claim-status-collector |
| `statusMessage` | no | Human-readable status detail. Updated by claim-status-collector |
| `lastCheckedAt` | no | Last time status was checked. Updated by claim-status-collector |

## Integration Points

### Claims CLI

- **On `render`**: Adds a new entry to `claims/registry.yaml`
- **On `delete`**: Removes the entry from `claims/registry.yaml`
- **On `list`**: Reads `claims/registry.yaml` directly or queries the claim-registry API

### Claim Registry API

- Reads `claims/registry.yaml` from the git repository (polling or webhook)
- Exposes REST endpoints:
  - `GET /api/v1/claims` - List all claims
  - `GET /api/v1/claims/{name}` - Get claim details
  - `GET /api/v1/claims?category=infra` - Filter by category
  - `GET /api/v1/claims?template=volumeclaim` - Filter by template

### Claim Status Collector

- Reads `claims/registry.yaml` to know which claims to check
- Updates `status`, `statusMessage`, and `lastCheckedAt` fields
- Commits updates back to git (direct push or PR)

### Backstage

- Queries the claim-registry API to display existing claims
- Uses claim metadata for delete operations (via Backstage template calling claims CLI)
- Catalog entries (`catalog-info.yaml`) remain per-claim for Backstage-native features (ownership, dependencies, TechInsights)

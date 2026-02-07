# Claims CLI

**Repository:** `stuttgart-things/claims`

## Overview

The claims CLI is the primary tool for creating and deleting Crossplane claims through the platform. It works independently of Backstage and can be used interactively, in CI/CD pipelines, or as a backend for Backstage custom actions.

## Commands

### `claims render` (existing)

Renders claim templates and creates pull requests.

```bash
# Interactive mode
claims render --api-url http://localhost:8080

# Non-interactive (CI/CD)
claims render \
  --api-url http://claim-machinery-api:8080 \
  --template-names volumeclaim \
  --params-file params.yaml \
  --output-dir ./claims/infra \
  --git-push \
  --create-pr
```

**Changes needed:** After rendering, also add an entry to `claims/registry.yaml`.

### `claims delete` (new)

Deletes claims by removing their files and creating a pull request.

```bash
# Interactive mode - select from existing claims
claims delete --repo stuttgart-things/harvester

# Non-interactive
claims delete \
  --repo stuttgart-things/harvester \
  --resource-name my-postgres \
  --category apps \
  --git-push \
  --create-pr

# Using claim-registry API for resolution
claims delete \
  --registry-url http://claim-registry:8080 \
  --resource-name my-postgres \
  --git-push \
  --create-pr
```

**What it does:**

1. Resolves claim metadata (from `--category` flag, registry API, or `registry.yaml`)
2. Clones the repository (or uses local checkout)
3. Creates a new branch (`delete-{name}`)
4. Removes `claims/{category}/{name}/` directory
5. Removes the entry from parent `kustomization.yaml`
6. Removes the entry from `claims/registry.yaml`
7. Commits, pushes, and creates a PR

### `claims list` (new)

Lists existing claims.

```bash
# From registry API
claims list --registry-url http://claim-registry:8080

# Filter by category
claims list --registry-url http://claim-registry:8080 --category infra
```

## Configuration

| Flag | Env Var | Description |
|------|---------|-------------|
| `--api-url` | `CLAIM_MACHINERY_API_URL` | claim-machinery-api URL for rendering |
| `--registry-url` | `CLAIM_REGISTRY_URL` | claim-registry API URL for listing/resolving |
| `--git-user` | `GIT_USER` | Git username for authentication |
| `--git-token` | `GIT_TOKEN` / `GITHUB_TOKEN` | Git token for authentication |
| `--repo` | - | GitHub repository slug (e.g., `stuttgart-things/harvester`) |

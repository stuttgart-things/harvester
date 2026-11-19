# Claims CLI

**Repository:** `stuttgart-things/claims`

## Overview

The claims CLI renders Crossplane claims through the claim-machinery-api and opens the pull request. It works independently of Backstage and can be used interactively, in CI/CD pipelines, or as a backend for Backstage custom actions.

## Commands

### `claims render`

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

### Deleting a claim

There is no `claims delete` here: delete by reverting the order PR (or a PR
that removes the XR file). On machinery-hv, ClusterStacks need the two-phase
delete. Both are described in
[Claim Lifecycle](../architecture/claim-lifecycle.md#delete). The registry
that `claims delete` / `claims list` were meant to use was never built and was
removed (harvester#348).

## Configuration

| Flag | Env Var | Description |
|------|---------|-------------|
| `--api-url` | `CLAIM_MACHINERY_API_URL` | claim-machinery-api URL for rendering |
| `--git-user` | `GIT_USER` | Git username for authentication |
| `--git-token` | `GIT_TOKEN` / `GITHUB_TOKEN` | Git token for authentication |
| `--repo` | - | GitHub repository slug (e.g., `stuttgart-things/harvester`) |

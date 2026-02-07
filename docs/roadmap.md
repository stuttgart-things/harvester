# Roadmap

## Implementation Phases

### Phase 1a: Claim Registry File

**Repository:** `stuttgart-things/harvester`

Establish `claims/registry.yaml` as the source of truth for all managed claims.

- [ ] Define registry schema (`claim-registry.io/v1alpha1`)
- [ ] Create initial `claims/registry.yaml` with existing claims
- [ ] Document schema and field reference
- [ ] Update Backstage claim-to-pull-request template to write registry entries on create

### Phase 1b: Claims CLI - Delete and Registry Support

**Repository:** `stuttgart-things/claims`

Extend the claims CLI with delete functionality and registry integration.

- [ ] `claims delete` subcommand (interactive + non-interactive)
  - [ ] Remove claim directory (`claims/{category}/{name}/`)
  - [ ] Remove entry from parent `kustomization.yaml`
  - [ ] Remove entry from `claims/registry.yaml`
  - [ ] Create PR with deletion changes
- [ ] `claims render` updates to write registry entry on create
- [ ] `claims list` subcommand (read from registry file or API)

### Phase 2: Claim Registry API

**Repository:** `stuttgart-things/claim-registry` (new)

Build a lightweight API that serves the claim inventory.

- [ ] REST API (`GET /api/v1/claims`, `GET /api/v1/claims/{name}`)
- [ ] Query filtering (category, template, status, source)
- [ ] Git sync (poll `registry.yaml` from harvester repo)
- [ ] Backstage integration (API proxy or custom catalog provider)
- [ ] Container image and Helm chart

### Phase 3: Claim Status Collector

**Repository:** `stuttgart-things/claim-status-collector` (new)

Monitor deployed claims and report health status.

- [ ] Kubernetes API integration for Crossplane claim status
- [ ] Registry updates (status, statusMessage, lastCheckedAt)
- [ ] Backstage catalog annotation updates
- [ ] Multi-cluster support
- [ ] Alerting webhooks on status change

## Dependencies

```
Phase 1a ──► Phase 1b ──► Phase 2 ──► Phase 3
                │                        │
                └──── can run in ────────┘
                      parallel
```

Phase 1a is the foundation. Phase 1b depends on the registry schema. Phase 2 and Phase 3 can be developed in parallel once the registry file exists.

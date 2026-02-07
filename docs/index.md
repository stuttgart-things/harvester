# Harvester

GitOps repository for Crossplane claims and infrastructure resources managed by the stuttgart-things platform team.

## What is Harvester?

Harvester is the **central GitOps repository** where all Crossplane claim manifests, Flux kustomizations, and Backstage catalog metadata live. It serves as the single source of truth for infrastructure resources provisioned through the claim-machinery platform.

## How It Works

Resources are created and deleted through a toolchain of independent services:

| Component | Purpose | Repository |
|-----------|---------|------------|
| **claim-machinery-api** | Renders KCL-based Crossplane claim templates | `stuttgart-things/claim-machinery-api` |
| **claims CLI** | Creates and deletes claims via terminal or CI/CD | `stuttgart-things/claims` |
| **claim-registry API** | Serves the inventory of existing claims | `stuttgart-things/claim-registry` |
| **claim-status-collector** | Monitors deployed claim health and updates catalog | `stuttgart-things/claim-status-collector` |
| **Backstage** | Developer portal UI for self-service provisioning | `stuttgart-things/backstage-resources` |

## Repository Structure

```
harvester/
├── claims/
│   ├── registry.yaml              # Source of truth for all claims
│   ├── infra/                     # Infrastructure claims
│   │   ├── kustomization.yaml
│   │   └── {resource-name}/
│   │       ├── {template}.yaml    # Crossplane claim manifest
│   │       ├── kustomization.yaml # Flux kustomization
│   │       └── catalog-info.yaml  # Backstage catalog entry
│   ├── apps/                      # Application claims
│   │   └── kustomization.yaml
│   └── other-resources/           # Other resource claims
│       └── kustomization.yaml
├── catalog-info.yaml              # Backstage Location (root)
├── mkdocs.yml                     # TechDocs config
└── docs/                          # This documentation
```

## Quick Links

- [Architecture Overview](architecture/overview.md)
- [Claim Lifecycle](architecture/claim-lifecycle.md)
- [Claim Registry](architecture/claim-registry.md)
- [Roadmap](roadmap.md)

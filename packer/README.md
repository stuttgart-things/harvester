# Harvester Packer Images

Packer builds for Harvester VM images, split into two governed tiers.

## Layout

```
packer/
├── _build/                     # Shared packer build logic — ONE copy for every image
│   ├── spec.pkr.hcl            # QEMU source + build + Harvester upload post-processor
│   ├── spec.cloud-init.pkr.hcl # Cloud-init user-data/meta-data generation
│   ├── variables.pkr.hcl       # Variable declarations (values come from each image's var-file)
│   ├── upload.sh               # Harvester image upload script
│   └── vmi_template.yaml       # Harvester VirtualMachineImage CRD template
│
├── golden/                     # Curated base images — REVIEW-GATED (no auto-merge)
│   └── sthings-u26/
│       ├── build.pkrvars.hcl   # source = upstream cloud image; image_name = sthings-u26
│       ├── users.yaml          # curated golden users
│       ├── packages.yaml       # curated golden packages
│       └── catalog-info.yaml   # type: packer-image-golden
│
└── dev/                        # Self-service playground images — AUTO-MERGE
    └── u26-dev/
        ├── build.pkrvars.hcl   # source = published golden artifact; image_name = u26-dev
        ├── users.yaml          # devs append their SSH keys here
        ├── packages.yaml       # devs append packages here
        └── catalog-info.yaml   # type: packer-image-dev
```

- **golden** — the trusted base. Changes go through review (CODEOWNERS + branch
  protection); merging builds + uploads the golden image.
- **dev** — a fast playground **layered on top of** the matching golden image, so a
  build only installs the delta (developers' keys + extra packages). Self-service
  via Backstage with auto-merge.

> `opensuse-leap/` still uses the legacy self-contained layout and is pending
> migration into `golden/`/`dev/` (see issue #93).

## CI / git flow

The two tiers share the same folder-driven mechanism (drop/edit a folder, CI picks
it up) but follow deliberately different governance:

- **Golden — review-gated.** The PR build is *validation-only*: it builds to prove
  the image works, but does **no upload and no auto-merge**. A human reviews and
  merges. After the merge to `main`, `packer-build.yml` rebuilds it, uploads it to
  Harvester, and (re)publishes the base to S3 (MinIO).
- **Dev — self-service.** The PR build **builds, uploads to Harvester, and
  auto-merges** on green — as long as the PR doesn't also touch a golden dir, which
  forces a review.

> **Bootstrap rule:** a new golden must be merged + published to S3 **once** before
> its dev image can build, because the dev's `source_url` points at the golden
> artifact in S3. So you don't land a brand-new golden + dev green in a single PR —
> **golden goes first**, then the dev image follows in a later PR.

## Building

The build always runs **from `packer/_build/`**, selecting an image with its var-file.
Because the working directory is `_build/`, the `users_file`/`packages_file` paths in
each var-file are relative to `_build/` (e.g. `../golden/sthings-u26/users.yaml`).

```bash
cd packer/_build
packer init .

# Golden image
packer build -var-file=../golden/sthings-u26/build.pkrvars.hcl .

# Dev image (layered on the published golden artifact)
packer build -var-file=../dev/u26-dev/build.pkrvars.hcl .
```

### Upload to Harvester

```bash
cd packer/_build
packer build \
  -var 'upload_to_harvester=true' \
  -var "harvester_vip=${HARVESTER_VIP}" \
  -var "harvester_password=${HARVESTER_PASSWORD}" \
  -var-file=../golden/sthings-u26/build.pkrvars.hcl .
```

### Variables

| Variable               | Default     | Description                                              |
|------------------------|-------------|----------------------------------------------------------|
| `source_url`           | (required)  | Base image: upstream cloud img (golden) or golden artifact (dev) |
| `source_checksum`      | `none`      | Checksum of `source_url` (`file:https://.../SHA256SUMS` or `none`) |
| `image_name`           | (required)  | Produced image / Harvester VMI name                      |
| `users_file`           | (required)  | Path to the image's `users.yaml` (relative to `_build/`) |
| `packages_file`        | (required)  | Path to the image's `packages.yaml` (relative to `_build/`) |
| `namespace`            | `default`   | Harvester namespace                                      |
| `output_location`      | `output/`   | Build output directory                                   |
| `upload_to_harvester`  | `false`     | Set `true` to upload after build                         |
| `harvester_vip`        | (empty)     | Harvester VIP address                                    |
| `harvester_password`   | (empty)     | Harvester admin password (sensitive)                     |

## Backstage

Two software templates drive these tiers:

- `harvester-packer-devimage` → edits `dev/<name>/`, auto-merge.
- `harvester-packer-adminimage` → edits `golden/<name>/`, review-gated draft PR.

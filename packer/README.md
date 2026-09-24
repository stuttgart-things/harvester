# Harvester Packer Images

Packer builds for Harvester VM images, split into two governed tiers.

## Layout

```
packer/
├── _build/                     # Shared packer build logic — ONE copy for every image
│   ├── spec.pkr.hcl            # QEMU source + build (no Harvester step — see below)
│   ├── spec.cloud-init.pkr.hcl # Cloud-init user-data/meta-data generation
│   ├── variables.pkr.hcl       # Variable declarations (values come from each image's var-file)
│   ├── publish-base.sh         # Publishes the built image to the MinIO artifact store
│   ├── register-image.sh       # Registers it with Harvester (Harvester downloads it)
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

> All images now use the `golden/` + `dev/` split on the shared `_build/` logic;
> the legacy self-contained per-OS folders have been retired (see issue #93).

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

### Getting an image onto Harvester

`packer build` only produces the image. Two ordered steps follow it, and the
order matters:

```bash
cd packer/_build

# 1. Publish to the MinIO artifact store.
IMAGE_FILE=output/sthings-u26-amd64.img \
IMAGE_NAME=sthings-u26 \
S3_PREFIX=golden \
S3_ENDPOINT=https://artifacts.platform.sthings.lab \
S3_BUCKET=packer \
MINIO_ACCESS_KEY=... MINIO_SECRET_KEY=... \
  bash publish-base.sh

# 2. Tell Harvester to download it from there.
UPLOAD_TO_HARVESTER=true \
HARVESTER_VIP="${HARVESTER_VIP}" \
HARVESTER_PASSWORD="${HARVESTER_PASSWORD}" \
IMAGE_NAME=sthings-u26 \
IMAGE_VERSION="$(date -u +%y.%-m%d.%H%M)" \
IMAGE_URL=https://artifacts.platform.sthings.lab/packer/golden/sthings-u26/sthings-u26-amd64.img \
  bash register-image.sh
```

**Harvester pulls the image itself** — the build host never streams it to
Harvester. The old path POSTed the whole ~1.8 GB body through the nginx in front
of the Harvester VIP and died on its 60 s `proxy-read-timeout` (issue #215).
Two consequences worth knowing:

- Harvester verifies the artifact URL's certificate against
  `settings.harvesterhci.io/additional-ca`. If that CA is stale, the image fails
  to import with `x509: certificate signed by unknown authority`.
- The bucket must be **public-read**: Harvester fetches anonymously.

#### Image names are versioned, and images are never replaced

`register-image.sh` registers `<image_name>-<version>` and refuses to overwrite
an existing image. An image cannot be replaced in place while a VM boots from
it: it owns a per-image Longhorn backing class (`lh-<uuid>`) backing those VMs'
disks, Harvester will not delete it under them, and recreating mints a *new*
uuid regardless — which invalidates the pins in
`clusters/crossplane-mgmt/platform/virtual-machine/env-config-virtualmachine.yaml`.

So a new image does not take effect on its own. After registering, move the pin
in that file to the new `imageId` + `storageClassName`; the CI job prints both
in its step summary. Existing VMs keep running on the old image until they are
rebuilt, which also makes rollback a one-line revert.

The MinIO key is *not* versioned — dev var-files point a stable `source_url` at
the golden artifact, and that URL has to keep resolving to the current base.

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

Harvester credentials are no longer packer variables — publishing and
registering happen after the build and read their config from the environment
(see above).

## Backstage

Two software templates drive these tiers:

- `harvester-packer-devimage` → edits `dev/<name>/`, auto-merge.
- `harvester-packer-adminimage` → edits `golden/<name>/`, review-gated draft PR.

# u26-dev (dev / playground)

Self-service developer image, **layered on top of the golden `sthings-u26`** image so
a build only installs the delta. Onboard yourself by adding your SSH key to
`users.yaml` and any packages you need to `packages.yaml` — the easiest way is the
`harvester-packer-devimage` Backstage template, which opens an **auto-merging** PR
and triggers the build.

This is a shared playground image: everyone's keys/packages accumulate here. For an
isolated or hardened image, use a golden image instead.

The build pulls the golden `sthings-u26` base over HTTPS from the MinIO artifact
store (`source_url` in `build.pkrvars.hcl`), published there by the golden build.

> ⚠️ The golden `sthings-u26` image must be **built + published at least once**
> before a dev build can run, otherwise the `source_url` returns 404.

## How a PR build reaches Harvester

Three ordered steps, and the order matters (issue #215):

1. `packer build` produces the qcow2.
2. `publish-base.sh` puts it in MinIO under `dev/u26-dev/`.
3. `register-image.sh` tells Harvester to download it from there.

Harvester **pulls the image itself** — nothing streams it there. Two things follow
from that: the bucket must stay public-read, and Harvester must trust the CA that
signed the artifact URL (`settings.harvesterhci.io/additional-ca`), or the image
fails to import with `x509: certificate signed by unknown authority`.

Each PR build registers its own image, named `u26-dev-pr<N>.<YY.MDD.HHMM>` —
images are never replaced in place, because Harvester will not delete one while a
VM boots from its Longhorn backing class. Consuming a new image means moving the
pin in
[`env-config-virtualmachine.yaml`](../../../clusters/crossplane-mgmt/platform/virtual-machine/env-config-virtualmachine.yaml);
the `ubuntu24` alias is what points at `u26-dev`.

Old per-PR images accumulate and are not cleaned up automatically — prune them on
Harvester when a PR is done with, checking first that nothing is pinned to them.

Build logic is shared in [`packer/_build/`](../../_build/). See
[`packer/README.md`](../../README.md) for how to build.

```bash
cd packer/_build
packer build -var-file=../dev/u26-dev/build.pkrvars.hcl .
```

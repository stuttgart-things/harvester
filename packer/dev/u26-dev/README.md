# u26-dev (dev / playground)

Self-service developer image, **layered on top of the golden `sthings-u26`** image so
a build only installs the delta. Onboard yourself by adding your SSH key to
`users.yaml` and any packages you need to `packages.yaml` — the easiest way is the
`harvester-packer-devimage` Backstage template, which opens an **auto-merging** PR
and triggers the build + upload.

This is a shared playground image: everyone's keys/packages accumulate here. For an
isolated or hardened image, use a golden image instead.

The build pulls the golden `sthings-u26` base over HTTPS from the MinIO artifact
store (`source_url` in `build.pkrvars.hcl`), published there by the golden build.

> ⚠️ The golden `sthings-u26` image must be **built + published at least once**
> before a dev build can run, otherwise the `source_url` returns 404.

Build logic is shared in [`packer/_build/`](../../_build/). See
[`packer/README.md`](../../README.md) for how to build.

```bash
cd packer/_build
packer build -var-file=../dev/u26-dev/build.pkrvars.hcl .
```

# u26-dev (dev / playground)

Self-service developer image, **layered on top of the golden `sthings-u26`** image so
a build only installs the delta. Onboard yourself by adding your SSH key to
`users.yaml` and any packages you need to `packages.yaml` — the easiest way is the
`harvester-packer-devimage` Backstage template, which opens an **auto-merging** PR
and triggers the build + upload.

This is a shared playground image: everyone's keys/packages accumulate here. For an
isolated or hardened image, use a golden image instead.

> ⚠️ Not buildable end-to-end yet: `build.pkrvars.hcl` has an empty `source_url`
> pending the golden → dev artifact handoff (issue #93).

Build logic is shared in [`packer/_build/`](../../_build/). See
[`packer/README.md`](../../README.md) for how to build.

```bash
cd packer/_build
packer build -var-file=../dev/u26-dev/build.pkrvars.hcl .
```

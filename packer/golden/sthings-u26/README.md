# sthings-u26 (golden)

Curated golden base image — **Ubuntu 26.04 LTS "Resolute"**, built fresh from the
upstream cloud image. This tier is **review-gated**: changes require review
(CODEOWNERS + branch protection); they are not auto-merged.

Edit `users.yaml` / `packages.yaml` to change what the golden base ships, then open
a PR (or use the `harvester-packer-adminimage` Backstage template).

Build logic is shared in [`packer/_build/`](../../_build/). See
[`packer/README.md`](../../README.md) for how to build.

```bash
cd packer/_build
packer build -var-file=../golden/sthings-u26/build.pkrvars.hcl .
```

# sthings-rocky9 (golden)

Curated golden base image — **Rocky Linux 9 (GenericCloud)**, built fresh from the
upstream cloud image. This tier is **review-gated**: changes require review
(CODEOWNERS + branch protection); they are not auto-merged.

Edit `users.yaml` / `packages.yaml` to change what the golden base ships, then open
a PR (or use the `harvester-packer-adminimage` Backstage template).

Build logic is shared in [`packer/_build/`](../../_build/); Rocky-specific knobs
(`ssh_username`, `qemuargs`, …) live in `build.pkrvars.hcl`. See
[`packer/README.md`](../../README.md) for how to build.

```bash
cd packer/_build
packer build -var-file=../golden/sthings-rocky9/build.pkrvars.hcl .
```

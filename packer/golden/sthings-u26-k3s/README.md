# sthings-u26-k3s (golden node image)

Ubuntu 26.04 golden base (`sthings-u26`) with the **k3s + cilium airgap images baked
in at build time**, so an edge node boots with **zero network dependency for the
cluster core**. containerd imports every tarball in `/var/lib/rancher/k3s/agent/images/`
on start — before any registry/mirror is reachable — which is what unblocks
"control plane never initializes" on a flaky link.

This is **stage-only (images)**: no install script and no systemd unit are baked, and
the **k3s binary is not baked** (it is not in the S3 `images` bucket — see below). The
images are the chicken-and-egg part; the binary is a small, separate concern.

## What gets baked

Pulled at **build time** from the flat S3 `images` bucket into
`/var/lib/rancher/k3s/agent/images/`:

| Tarball | Size | Purpose |
|---------|------|---------|
| `k3s-airgap-images-amd64.tar.zst` | ~232 MiB | k3s core images |
| `cilium-images.tar` | ~349 MiB | CNI images |

Driven by the shared `packer/_build/stage-airgap-images.sh` provisioner. The S3 bucket
is a *build-time* artifact source — edge nodes never fetch it at provision time.

## Provisioning a node

The baked images let k3s come up offline once it's installed. Wire up the binary +
service at provision time, e.g.:

```bash
INSTALL_K3S_SKIP_DOWNLOAD=true k3s-install.sh   # if the binary is present
# or fetch the matching k3s binary once at provision and place /usr/local/bin/k3s
```

> The **k3s binary** is intentionally not staged (the `images` bucket holds image
> tarballs only). If you want it baked too, drop the `k3s` binary in S3 (or pin a
> version to fetch from the GitHub release at build time) and we'll extend the bake.

## Layout & build

Layered on the published golden `sthings-u26` base (S3), like dev images, so the build
only adds the airgap delta. Knobs live in `build.pkrvars.hcl`:

- `airgap_image_tars` — tarballs to stage (k3s + cilium here).
- `airgap_images_base_url` / `airgap_images_dir` — source bucket / destination.
- `disk_size` — bumped to `20G` for the images.

```bash
cd packer/_build
packer build -var-file=../golden/sthings-u26-k3s/build.pkrvars.hcl .
```

> ⚠️ Prerequisites: the golden `sthings-u26` base must be built + published to S3, and
> the tarballs in `airgap_image_tars` must exist in the S3 `images` bucket.

See [`packer/README.md`](../../README.md) for the golden/dev model.

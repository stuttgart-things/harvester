# sthings-u26-k3s (golden node image)

Ubuntu 26.04 golden base (`sthings-u26`) with the **k3s airgap artifacts baked in
at build time** — the binary and the airgap images tarball — so an edge node boots
with **zero network dependency for the k3s core**. containerd loads the cluster
images from the local store before any registry/mirror is reachable, which is what
unblocks "control plane never initializes" on a flaky link.

This is **stage-only**: no install script and no systemd unit are baked. The node
wires up k3s at provision time against the prebaked artifacts, e.g.:

```bash
INSTALL_K3S_SKIP_DOWNLOAD=true k3s-install.sh   # uses /usr/local/bin/k3s + staged images
```

## What gets baked

| Artifact | Destination in image |
|----------|----------------------|
| `k3s` binary | `/usr/local/bin/k3s` |
| `k3s-airgap-images-amd64.tar.zst` | `/var/lib/rancher/k3s/agent/images/` |

Pulled at **build time** from S3 (`k3s_artifacts_base_url`/`k3s_version`/…) via the
shared `packer/_build/stage-k3s-airgap.sh` provisioner. The S3 bucket is a
*build-time* artifact source — edge nodes never fetch it at provision time.

## Layout & build

Layered on the published golden `sthings-u26` base (S3), like dev images, so the
build only installs the k3s delta. Knobs live in `build.pkrvars.hcl`:

- `k3s_version` — **pin** to a release present in S3 at `<base>/<version>/`.
- `disk_size` — bumped to `20G` for the airgap images.

```bash
cd packer/_build
packer build -var-file=../golden/sthings-u26-k3s/build.pkrvars.hcl .
```

> ⚠️ Prerequisites: the golden `sthings-u26` base must be built + published to S3,
> and the k3s airgap artifacts (`k3s`, `k3s-airgap-images-amd64.tar.zst`,
> `sha256sum-amd64.txt`) must exist at
> `${k3s_artifacts_base_url}/${k3s_version}/` before this builds.

See [`packer/README.md`](../../README.md) for the golden/dev model.

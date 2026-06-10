# Harvester image import (from S3)

Ingest the **golden** base images that are already published to the S3/MinIO
artifact store into Harvester, **without** a packer build or the KVM runner.

`packer/_build/upload.sh` streams a *locally-built* image into Harvester
(`sourceType: upload`) and is therefore tied to the build runner. Once a golden
base is in S3, Harvester can pull it itself via a `sourceType: download`
`VirtualMachineImage` — that is what this directory does.

## Files

| File | Purpose |
|------|---------|
| `golden-images.yaml` | `VirtualMachineImage` (download) manifests for `sthings-u26`, `sthings-rocky9`, `sthings-leap` |
| `import-golden.sh` | Trusts the private CA, then applies the manifests in the right order |

> Kept out of `packer/golden/**` on purpose: that path is folder-driven by
> `packer-pr-build.yml`, which would mistake a loose file here for an image dir.

## Private CA prerequisite ⚠️

The artifact endpoint `artifacts.platform.sthings.lab` is served by the
**sthings-lab private CA** (Vault PKI). Harvester's download path **verifies TLS
and has no insecure option**, so the import fails with
`x509: certificate signed by unknown authority` until Harvester trusts that root
via the `additional-ca` Setting.

The build scripts (`curl -sk`, `mc`) skip verification and so never hit this — the
download path does.

## Usage

```bash
# Sets additional-ca from Vault PKI, then applies the VMIs:
KUBECONFIG=<harvester-kubeconfig> ./import-golden.sh

# Already have the CA on disk?
KUBECONFIG=<harvester-kubeconfig> CA_FILE=./sthings-lab-ca.crt ./import-golden.sh

# Watch import progress:
kubectl -n default get virtualmachineimages -w
```

Or do it by hand: set `additional-ca` (append-safe), then
`kubectl apply -f golden-images.yaml`.

## Notes

- **Verify the issuer** if MinIO is fronted by a different cert than Vault PKI:
  `openssl s_client -connect artifacts.platform.sthings.lab:443 -showcerts`, and
  trust *that* chain.
- **Checksum** is intentionally omitted from the VMIs. `publish-base.sh` writes a
  `.sha256` sidecar, but Harvester's `spec.checksum` expects **SHA512** — a sha256
  there would fail verification. Publish a `.sha512` to enable it.
- `additional-ca` is appended to, not overwritten, so existing trusted CAs stay put.

#!/usr/bin/env bash
set -euo pipefail

# Stage k3s airgap artifacts into the image at BUILD time (binary + images
# tarball) so edge nodes boot with ZERO network dependency for the k3s core
# (containerd loads the images from the local store before any registry/mirror
# is reachable). "Stage only": no install script, no systemd unit — the node
# wires up k3s at provision time, e.g.:
#   INSTALL_K3S_SKIP_DOWNLOAD=true k3s-install.sh   (or a prebaked unit + config)
#
# Runs as a packer shell provisioner inside the guest. No-op unless K3S_VERSION
# is set. Artifacts are pulled from S3 over the private CA with `curl -k`
# (build-time only — matches publish-base.sh / upload.sh).

K3S_VERSION="${K3S_VERSION:-}"
K3S_ARTIFACTS_BASE_URL="${K3S_ARTIFACTS_BASE_URL:-https://artifacts.platform.sthings.lab/k3s}"

if [ -z "${K3S_VERSION}" ]; then
  echo "K3S_VERSION not set — skipping k3s airgap staging."
  exit 0
fi

BASE="${K3S_ARTIFACTS_BASE_URL}/${K3S_VERSION}"
IMAGES_DIR="/var/lib/rancher/k3s/agent/images"
IMAGES_TAR="k3s-airgap-images-amd64.tar.zst"
BIN_DST="/usr/local/bin/k3s"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

echo "Staging k3s ${K3S_VERSION} airgap artifacts from ${BASE} ..."

# 1. Download binary, airgap images and checksums.
curl -kfsSL "${BASE}/k3s"            -o "${TMP}/k3s"
curl -kfsSL "${BASE}/${IMAGES_TAR}"  -o "${TMP}/${IMAGES_TAR}"
curl -kfsSL "${BASE}/sha256sum-amd64.txt" -o "${TMP}/sha256sum-amd64.txt" || true

# 2. Verify checksums when the sums file is present (k3s ships one per release).
if [ -s "${TMP}/sha256sum-amd64.txt" ]; then
  echo "Verifying checksums ..."
  ( cd "${TMP}" && grep -E "  (k3s|${IMAGES_TAR})\$" sha256sum-amd64.txt | sha256sum -c - )
else
  echo "WARN: sha256sum-amd64.txt missing — skipping checksum verification."
fi

# 3. Place artifacts (binary executable; images readable by containerd).
sudo install -D -m 0755 "${TMP}/k3s" "${BIN_DST}"
sudo install -d -m 0755 "${IMAGES_DIR}"
sudo install -m 0644 "${TMP}/${IMAGES_TAR}" "${IMAGES_DIR}/${IMAGES_TAR}"

echo "k3s ${K3S_VERSION} staged:"
echo "  binary : ${BIN_DST}"
echo "  images : ${IMAGES_DIR}/${IMAGES_TAR}"

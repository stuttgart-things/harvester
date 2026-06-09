#!/usr/bin/env bash
set -euo pipefail

# Stage airgap IMAGE tarballs into the engine's agent images dir at BUILD time,
# so edge nodes boot with ZERO network dependency for the cluster core:
# containerd imports every tarball in this dir on start, before any
# registry/mirror is reachable (which is what unblocks "control plane never
# initializes" on a flaky link).
#
# "Stage only" — images only. The k3s/rke2 binary + service are wired up at
# provision time (the binary is small; the images are the chicken-and-egg part).
#
# Runs as a packer shell provisioner inside the guest. No-op unless
# AIRGAP_IMAGE_TARS is set. Tarballs are pulled from the flat S3 'images' bucket
# over the private CA with `curl -k` (build-time only — matches
# publish-base.sh / upload.sh).
#
# Env:
#   AIRGAP_IMAGE_TARS       comma-separated object names (e.g.
#                           "k3s-airgap-images-amd64.tar.zst,cilium-images.tar")
#   AIRGAP_IMAGES_BASE_URL  base URL of the bucket (default artifacts .../images)
#   AIRGAP_IMAGES_DIR       destination dir (default k3s agent images)

AIRGAP_IMAGE_TARS="${AIRGAP_IMAGE_TARS:-}"
AIRGAP_IMAGES_BASE_URL="${AIRGAP_IMAGES_BASE_URL:-https://artifacts.platform.sthings.lab/images}"
AIRGAP_IMAGES_DIR="${AIRGAP_IMAGES_DIR:-/var/lib/rancher/k3s/agent/images}"

if [ -z "${AIRGAP_IMAGE_TARS}" ]; then
  echo "AIRGAP_IMAGE_TARS not set — skipping airgap image staging."
  exit 0
fi

echo "Staging airgap images into ${AIRGAP_IMAGES_DIR} from ${AIRGAP_IMAGES_BASE_URL} ..."
sudo install -d -m 0755 "${AIRGAP_IMAGES_DIR}"

IFS=',' read -ra TARS <<<"${AIRGAP_IMAGE_TARS}"
for tar in "${TARS[@]}"; do
  tar="$(echo "${tar}" | xargs)"   # trim whitespace
  [ -n "${tar}" ] || continue
  tmp="$(mktemp)"
  echo "  -> ${tar}"
  curl -kfSL "${AIRGAP_IMAGES_BASE_URL}/${tar}" -o "${tmp}"
  sudo install -m 0644 "${tmp}" "${AIRGAP_IMAGES_DIR}/${tar}"
  rm -f "${tmp}"
done

echo "Staged airgap images:"
sudo ls -lh "${AIRGAP_IMAGES_DIR}"

#!/usr/bin/env bash
set -euo pipefail

# Publish a built image (+ sha256) to the MinIO artifact store. It serves two
# consumers, which is why dev images are published too and not just golden ones:
#   * dev builds layer on a golden via a plain HTTPS source_url (no Harvester auth)
#   * register-image.sh hands Harvester this URL to download from (issue #215)
#
# Required env:
#   IMAGE_FILE         path to the built image, e.g. output/sthings-u26-amd64.img
#   IMAGE_NAME         image name, e.g. sthings-u26
#   S3_ENDPOINT        MinIO endpoint, e.g. https://artifacts.platform.sthings.lab
#   S3_BUCKET          target bucket (MUST be public-read: packer GETs the source_url
#                      and Harvester pulls the image anonymously)
#   MINIO_ACCESS_KEY   upload credential
#   MINIO_SECRET_KEY   upload credential
# Optional:
#   S3_PREFIX          tier prefix (default: golden). Dev builds pass "dev".
#
# Object layout (path-style):
#   <S3_ENDPOINT>/<S3_BUCKET>/<S3_PREFIX>/<IMAGE_NAME>/<IMAGE_NAME>-amd64.img(.sha256)
#
# The key is deliberately NOT versioned: dev var-files point a stable source_url
# at the golden artifact, and that URL must keep resolving to the current base.
# Versioning happens on the Harvester side, in the VMI name.

IMAGE_FILE="${IMAGE_FILE:?IMAGE_FILE is required}"
IMAGE_NAME="${IMAGE_NAME:?IMAGE_NAME is required}"
S3_ENDPOINT="${S3_ENDPOINT:?S3_ENDPOINT is required}"
S3_BUCKET="${S3_BUCKET:?S3_BUCKET is required}"
: "${MINIO_ACCESS_KEY:?MINIO_ACCESS_KEY is required}"
: "${MINIO_SECRET_KEY:?MINIO_SECRET_KEY is required}"

if [ ! -f "${IMAGE_FILE}" ]; then
  echo "ERROR: image file not found: ${IMAGE_FILE}" >&2
  exit 1
fi

S3_PREFIX="${S3_PREFIX:-golden}"
KEY="${S3_PREFIX}/${IMAGE_NAME}/${IMAGE_NAME}-amd64.img"

echo "Computing sha256 for ${IMAGE_FILE}..."
sha256sum "${IMAGE_FILE}" | awk '{print $1}' > "${IMAGE_FILE}.sha256"

# Use the MinIO client; fetch a local copy if it is not already on the runner.
MC="$(command -v mc || true)"
if [ -z "${MC}" ]; then
  echo "mc not found — downloading client..."
  curl -fsSL https://dl.min.io/client/mc/release/linux-amd64/mc -o ./mc
  chmod +x ./mc
  MC="./mc"
fi

"${MC}" alias set artifacts "${S3_ENDPOINT}" "${MINIO_ACCESS_KEY}" "${MINIO_SECRET_KEY}" >/dev/null

echo "Uploading ${IMAGE_FILE} -> s3://${S3_BUCKET}/${KEY}"
"${MC}" cp "${IMAGE_FILE}"        "artifacts/${S3_BUCKET}/${KEY}"
"${MC}" cp "${IMAGE_FILE}.sha256" "artifacts/${S3_BUCKET}/${KEY}.sha256"

IMAGE_URL="${S3_ENDPOINT}/${S3_BUCKET}/${KEY}"
echo "Published: ${IMAGE_URL}"

# register-image.sh needs this URL; hand it to the next workflow step rather
# than having both sides rebuild the same key from parts.
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "image_url=${IMAGE_URL}" >> "${GITHUB_OUTPUT}"
fi

#!/bin/bash
set -euo pipefail

# Set defaults or check for required variables
IMAGE_FILE="${IMAGE_FILE:-}" # required
IMAGE_NAME="${IMAGE_NAME:-}" # required
NAMESPACE="${NAMESPACE:-default}"

if [ -z "$IMAGE_FILE" ]; then
  echo "ERROR: IMAGE_FILE is not set."
  exit 1
fi
if [ -z "$IMAGE_NAME" ]; then
  echo "ERROR: IMAGE_NAME is not set."
  exit 1
fi

if [ "${UPLOAD_TO_HARVESTER}" != "true" ]; then
  echo "Skipping Harvester upload (UPLOAD_TO_HARVESTER != true)"
  exit 0
fi

if [ -z "${HARVESTER_VIP}" ] || [ -z "${HARVESTER_PASSWORD}" ]; then
  echo "ERROR: HARVESTER_VIP and HARVESTER_PASSWORD must be set when uploading"
  exit 1
fi

echo "Authenticating against Harvester at ${HARVESTER_VIP}..."
TOKEN=$(curl -sk -X POST "https://${HARVESTER_VIP}/v3-public/localProviders/local?action=login" \
  -H 'content-type: application/json' \
  -d '{"username":"admin","password":"'"${HARVESTER_PASSWORD}"'"}' | jq -r '.token')

if [ -z "${TOKEN}" ] || [ "${TOKEN}" = "null" ]; then
  echo "ERROR: Failed to authenticate against Harvester"
  exit 1
fi

IMAGE_SIZE=$(stat -c%s "${IMAGE_FILE}")

# Delete existing image if it exists so we can overwrite
echo "Checking for existing VirtualMachineImage ${IMAGE_NAME} in namespace ${NAMESPACE}..."
HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" \
  -H "Authorization: Bearer ${TOKEN}" \
  "https://${HARVESTER_VIP}/v1/harvester/harvesterhci.io.virtualmachineimages/${NAMESPACE}/${IMAGE_NAME}")

if [ "${HTTP_CODE}" = "200" ]; then
  echo "Existing image found, deleting..."
  curl -sk -X DELETE \
    -H "Authorization: Bearer ${TOKEN}" \
    "https://${HARVESTER_VIP}/v1/harvester/harvesterhci.io.virtualmachineimages/${NAMESPACE}/${IMAGE_NAME}" &> /dev/null
  echo "Waiting for image deletion to complete..."
  for _ in $(seq 1 30); do
    HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" \
      -H "Authorization: Bearer ${TOKEN}" \
      "https://${HARVESTER_VIP}/v1/harvester/harvesterhci.io.virtualmachineimages/${NAMESPACE}/${IMAGE_NAME}")
    if [ "${HTTP_CODE}" = "404" ]; then
      echo "Image deleted."
      break
    fi
    sleep 5
  done
fi

echo "Creating VirtualMachineImage ${IMAGE_NAME} in namespace ${NAMESPACE}..."
yq -j '.metadata.name = "'"${IMAGE_NAME}"'" | .spec.displayName = "'"${IMAGE_NAME}"'"' vmi_template.yaml | \
  curl -sk -X POST \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    --data-binary @- \
    "https://${HARVESTER_VIP}/v1/harvester/harvesterhci.io.virtualmachineimages/${NAMESPACE}" &> /dev/null

echo "Uploading image ${IMAGE_FILE} (${IMAGE_SIZE} bytes)..."
curl -sk -X POST \
  -H "Authorization: Bearer ${TOKEN}" \
  -F "chunk=@${IMAGE_FILE}" \
  "https://${HARVESTER_VIP}/v1/harvester/harvesterhci.io.virtualmachineimages/${NAMESPACE}/${IMAGE_NAME}?action=upload&size=${IMAGE_SIZE}"

echo "Upload complete."

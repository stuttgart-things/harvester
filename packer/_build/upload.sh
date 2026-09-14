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

# curl -s exits 0 for a 504 — the request succeeded, the response just says no.
# Every write below therefore has to look at the status itself. api_write prints
# the body on failure, because a bare code is not enough to tell an ingress
# timeout from a Harvester rejection.
api_write() {
  local desc="$1"; shift
  local body code
  body="$(mktemp)"
  code=$(curl -sk -o "${body}" -w '%{http_code}' "$@" || true)
  case "${code}" in
    2*) rm -f "${body}"; return 0 ;;
    *)
      echo "ERROR: ${desc} failed with HTTP ${code:-<none>}"
      echo "--- response ---"
      head -c 600 "${body}"; echo
      rm -f "${body}"
      return 1
      ;;
  esac
}

IMAGE_SIZE=$(stat -c%s "${IMAGE_FILE}")

# Delete existing image if it exists so we can overwrite
echo "Checking for existing VirtualMachineImage ${IMAGE_NAME} in namespace ${NAMESPACE}..."
HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" \
  -H "Authorization: Bearer ${TOKEN}" \
  "https://${HARVESTER_VIP}/v1/harvester/harvesterhci.io.virtualmachineimages/${NAMESPACE}/${IMAGE_NAME}")

if [ "${HTTP_CODE}" = "200" ]; then
  echo "Existing image found, deleting..."
  api_write "deleting ${IMAGE_NAME}" -X DELETE \
    -H "Authorization: Bearer ${TOKEN}" \
    "https://${HARVESTER_VIP}/v1/harvester/harvesterhci.io.virtualmachineimages/${NAMESPACE}/${IMAGE_NAME}"
  echo "Waiting for image deletion to complete..."
  DELETED=false
  for _ in $(seq 1 30); do
    HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" \
      -H "Authorization: Bearer ${TOKEN}" \
      "https://${HARVESTER_VIP}/v1/harvester/harvesterhci.io.virtualmachineimages/${NAMESPACE}/${IMAGE_NAME}")
    if [ "${HTTP_CODE}" = "404" ]; then
      echo "Image deleted."
      DELETED=true
      break
    fi
    sleep 5
  done

  # Running out of this loop used to be indistinguishable from success, and the
  # script carried on to create and upload over an image that was still there.
  #
  # The usual cause is that the image is still in use: its per-image Longhorn
  # backing class (lh-<uuid>) backs the boot disk of running VMs, and Harvester
  # will not remove it under them. That is a good refusal — deleting it would
  # pull the backing image out from under those VMs, and recreating mints a NEW
  # lh-<uuid>, which is what invalidates the pins in
  # clusters/crossplane-mgmt/platform/virtual-machine/env-config-virtualmachine.yaml.
  #
  # So: stop, and say what to look at.
  if [ "${DELETED}" != "true" ]; then
    echo "ERROR: ${IMAGE_NAME} was not deleted after 150s — refusing to upload over it."
    echo "Most likely it still backs running VMs. Check which:"
    echo "  kubectl -n ${NAMESPACE} get virtualmachineimage ${IMAGE_NAME} -o jsonpath='{.status.storageClassName}'"
    echo "  kubectl get pvc -A -o json | jq -r '.items[] | select(.spec.storageClassName==\"<that class>\") | \"\(.metadata.namespace)/\(.metadata.name)\"'"
    exit 1
  fi
fi

echo "Creating VirtualMachineImage ${IMAGE_NAME} in namespace ${NAMESPACE}..."
yq -j '.metadata.name = "'"${IMAGE_NAME}"'" | .spec.displayName = "'"${IMAGE_NAME}"'"' vmi_template.yaml | \
  api_write "creating ${IMAGE_NAME}" -X POST \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    --data-binary @- \
    "https://${HARVESTER_VIP}/v1/harvester/harvesterhci.io.virtualmachineimages/${NAMESPACE}"

echo "Uploading image ${IMAGE_FILE} (${IMAGE_SIZE} bytes)..."
# Force HTTP/1.1: large multipart uploads over HTTP/2 fail with curl exit 92
# (CURLE_HTTP2_STREAM / framing-layer stream error) against Harvester.
api_write "uploading ${IMAGE_NAME}" -X POST --http1.1 \
  -H "Authorization: Bearer ${TOKEN}" \
  -F "chunk=@${IMAGE_FILE}" \
  "https://${HARVESTER_VIP}/v1/harvester/harvesterhci.io.virtualmachineimages/${NAMESPACE}/${IMAGE_NAME}?action=upload&size=${IMAGE_SIZE}"

echo "Upload complete."

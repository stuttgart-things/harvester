#!/usr/bin/env bash
set -euo pipefail

# Register a built image with Harvester by pointing it at the artifact that
# publish-base.sh has already put in MinIO. Harvester downloads it itself
# (sourceType: download); nothing streams through this script.
#
# Why not POST the image any more (issue #215): the old upload pushed the whole
# ~1.8 GB body through the nginx that fronts the Harvester VIP, which cut it off
# at the default 60s proxy-read-timeout. Raising that timeout only moves the
# limit — the next image walks into the new one. Handing Harvester a URL takes
# the proxy out of the transfer entirely: no timeout, no proxy-body-size, and no
# need for the --http1.1 workaround the multipart upload required.
#
# Harvester verifies IMAGE_URL's certificate itself, so the CA that signed it
# must be in settings.harvesterhci.io/additional-ca. A CA mismatch shows up as
# "x509: certificate signed by unknown authority" in the image's conditions.
#
# Images are registered under a VERSIONED name and NEVER replace an existing
# one. In-place replacement is not possible while a VM boots from the image: it
# owns a per-image Longhorn backing class (lh-<uuid>) that backs those VMs'
# disks, Harvester refuses to delete it under them, and recreating mints a NEW
# uuid anyway — which invalidates the pins in
# clusters/crossplane-mgmt/platform/virtual-machine/env-config-virtualmachine.yaml.
#
# Required env:
#   HARVESTER_VIP       Harvester endpoint (host, no scheme)
#   HARVESTER_PASSWORD  admin password
#   IMAGE_NAME          base image name, e.g. sthings-u26
#   IMAGE_VERSION       version suffix, e.g. 26.924.1130
#   IMAGE_URL           public URL of the published artifact
# Optional:
#   NAMESPACE           Harvester namespace (default: default)
#   REGISTER_TIMEOUT    seconds to wait for the import (default: 1800)

UPLOAD_TO_HARVESTER="${UPLOAD_TO_HARVESTER:-false}"
NAMESPACE="${NAMESPACE:-default}"
REGISTER_TIMEOUT="${REGISTER_TIMEOUT:-1800}"

if [ "${UPLOAD_TO_HARVESTER}" != "true" ]; then
  echo "Skipping Harvester registration (UPLOAD_TO_HARVESTER != true)"
  exit 0
fi

: "${HARVESTER_VIP:?HARVESTER_VIP is required}"
: "${HARVESTER_PASSWORD:?HARVESTER_PASSWORD is required}"
: "${IMAGE_NAME:?IMAGE_NAME is required}"
: "${IMAGE_VERSION:?IMAGE_VERSION is required}"
: "${IMAGE_URL:?IMAGE_URL is required}"

VMI_NAME="${IMAGE_NAME}-${IMAGE_VERSION}"
API="https://${HARVESTER_VIP}/v1/harvester/harvesterhci.io.virtualmachineimages"

# The artifact has to be readable before Harvester is told to go and get it —
# otherwise the failure surfaces 3 retries later as an opaque image condition.
echo "Checking ${IMAGE_URL} is reachable..."
SRC_CODE=$(curl -sSI -o /dev/null -w '%{http_code}' --max-time 30 "${IMAGE_URL}" || true)
if [ "${SRC_CODE}" != "200" ]; then
  echo "ERROR: ${IMAGE_URL} is not publicly readable (HTTP ${SRC_CODE:-<none>})."
  echo "Harvester pulls this URL anonymously — publish-base.sh must run first and"
  echo "the bucket must be public-read."
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
# So look at the status, and print the body, because a bare code cannot tell an
# ingress timeout from a Harvester rejection.
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

# A versioned name is meant to be new. If it already exists, something is wrong
# (a rerun, or a clashing version) — refuse rather than quietly adopt it.
EXISTS=$(curl -sk -o /dev/null -w '%{http_code}' \
  -H "Authorization: Bearer ${TOKEN}" "${API}/${NAMESPACE}/${VMI_NAME}")
if [ "${EXISTS}" = "200" ]; then
  echo "ERROR: ${VMI_NAME} already exists in ${NAMESPACE}."
  echo "Versioned images are immutable — bump IMAGE_VERSION, or delete that image"
  echo "first if it was a failed attempt and no VM uses it."
  exit 1
fi

echo "Creating VirtualMachineImage ${VMI_NAME} (download from ${IMAGE_URL})..."
yq -o=json '
  .metadata.name = "'"${VMI_NAME}"'" |
  .spec.displayName = "'"${VMI_NAME}"'" |
  .spec.url = "'"${IMAGE_URL}"'"
' vmi_template.yaml | \
  api_write "creating ${VMI_NAME}" -X POST \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    --data-binary @- \
    "${API}/${NAMESPACE}"

# Creating the object only queues the download. The import is what can fail —
# bad URL, untrusted CA, out of space — and it fails asynchronously, so the
# script is not done until Harvester says Imported.
echo "Waiting for Harvester to import the image (timeout ${REGISTER_TIMEOUT}s)..."
DEADLINE=$(( $(date +%s) + REGISTER_TIMEOUT ))
LAST_PROGRESS=""
while [ "$(date +%s)" -lt "${DEADLINE}" ]; do
  STATUS=$(curl -sk -H "Authorization: Bearer ${TOKEN}" "${API}/${NAMESPACE}/${VMI_NAME}" || true)

  IMPORTED=$(echo "${STATUS}" | jq -r '.status.conditions[]? | select(.type=="Imported") | .status' 2>/dev/null || echo "")
  FAILED=$(echo "${STATUS}" | jq -r '.status.conditions[]? | select(.type=="RetryLimitExceeded") | .status' 2>/dev/null || echo "")
  PROGRESS=$(echo "${STATUS}" | jq -r '.status.progress // "0"' 2>/dev/null || echo "0")

  if [ "${FAILED}" = "True" ]; then
    echo "ERROR: Harvester could not import ${VMI_NAME}:"
    echo "${STATUS}" | jq -r '.status.conditions[]? | select(.type=="RetryLimitExceeded") | .message'
    exit 1
  fi

  if [ "${IMPORTED}" = "True" ]; then
    SC=$(echo "${STATUS}" | jq -r '.status.storageClassName')
    SIZE=$(echo "${STATUS}" | jq -r '.status.size')
    echo "Imported: ${VMI_NAME} (${SIZE} bytes)"
    echo
    echo "Storage class: ${SC}"
    echo
    echo "Pin this in clusters/crossplane-mgmt/platform/virtual-machine/env-config-virtualmachine.yaml:"
    echo "      ${IMAGE_NAME}:"
    echo "        imageId: ${NAMESPACE}/${VMI_NAME}"
    echo "        storageClassName: ${SC}"
    # Surface both to the workflow so a later step can use them.
    if [ -n "${GITHUB_OUTPUT:-}" ]; then
      {
        echo "vmi_name=${VMI_NAME}"
        echo "storage_class=${SC}"
      } >> "${GITHUB_OUTPUT}"
    fi
    exit 0
  fi

  if [ "${PROGRESS}" != "${LAST_PROGRESS}" ]; then
    echo "  progress: ${PROGRESS}%"
    LAST_PROGRESS="${PROGRESS}"
  fi
  sleep 10
done

echo "ERROR: ${VMI_NAME} was not imported within ${REGISTER_TIMEOUT}s — last progress ${LAST_PROGRESS:-0}%."
echo "Inspect it with:"
echo "  kubectl -n ${NAMESPACE} get virtualmachineimage ${VMI_NAME} -o yaml"
exit 1

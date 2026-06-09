#!/usr/bin/env bash
set -euo pipefail

# Import the golden images (already published to S3) into Harvester via
# sourceType: download VMIs.
#
# The S3 endpoint (artifacts.platform.sthings.lab) is served by the sthings-lab
# private CA. Harvester's image-download path verifies TLS and has NO insecure
# option, so this script trusts that root via Setting/additional-ca FIRST, then
# applies the VirtualMachineImage manifests.
#
# Requires: kubectl + jq + curl, with KUBECONFIG pointed at the HARVESTER cluster.
#
# Env:
#   VAULT_CA_URL  CA source (default: https://vault.infra.sthings.lab/v1/pki/ca/pem)
#   CA_FILE       path to a PEM file; overrides VAULT_CA_URL when set
#   MANIFEST      VMI manifest (default: <script dir>/golden-images.yaml)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="${MANIFEST:-${SCRIPT_DIR}/golden-images.yaml}"
VAULT_CA_URL="${VAULT_CA_URL:-https://vault.infra.sthings.lab/v1/pki/ca/pem}"

# 1. Obtain the sthings-lab root CA (public material — a cert, not a key).
if [ -n "${CA_FILE:-}" ]; then
  CA_PEM="$(cat "${CA_FILE}")"
else
  echo "Fetching sthings-lab CA from ${VAULT_CA_URL}..."
  CA_PEM="$(curl -sk "${VAULT_CA_URL}")"
fi
if ! grep -q "BEGIN CERTIFICATE" <<<"${CA_PEM}"; then
  echo "ERROR: no PEM certificate obtained — set CA_FILE or VAULT_CA_URL" >&2
  exit 1
fi

# 2. Trust it on Harvester (append-safe) so the download path can verify the
#    artifacts.platform.sthings.lab server certificate.
CURRENT="$(kubectl get settings.harvesterhci.io additional-ca -o jsonpath='{.value}' 2>/dev/null || true)"
if grep -qF "${CA_PEM}" <<<"${CURRENT}"; then
  echo "additional-ca already trusts the sthings-lab CA; leaving it unchanged."
else
  echo "Appending sthings-lab CA to Harvester additional-ca..."
  NEW_VALUE="$(printf '%s\n%s\n' "${CURRENT}" "${CA_PEM}" | sed '/^[[:space:]]*$/d')"
  kubectl patch settings.harvesterhci.io additional-ca --type merge \
    -p "$(jq -n --arg v "${NEW_VALUE}" '{value:$v}')"
fi

# 3. Import the golden images — Harvester pulls each image from S3.
echo "Applying golden image VMIs from ${MANIFEST}..."
kubectl apply -f "${MANIFEST}"

echo
echo "Done. Watch progress with:"
echo "  kubectl -n default get virtualmachineimages -w"

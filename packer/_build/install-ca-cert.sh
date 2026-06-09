#!/usr/bin/env bash
set -euo pipefail

# Install the sthings-lab private CA into the image's system trust store at BUILD
# time and refresh the trust store, so VMs from this image trust *.sthings.lab
# (Vault PKI / cert-manager) without any per-VM config.
#
# Fetched with `curl -sk` because the Vault endpoint serving the CA is itself
# fronted by this CA (chicken-and-egg) — build-time only. No-op if CA_CERT_URL
# is empty.
#
# Env:
#   CA_CERT_URL   PEM CA endpoint (e.g. https://vault.infra.sthings.lab/v1/pki/ca/pem)
#   CA_CERT_NAME  filename in the trust anchors dir (default sthings-lab-ca.crt)

CA_CERT_URL="${CA_CERT_URL:-}"
CA_CERT_NAME="${CA_CERT_NAME:-sthings-lab-ca.crt}"

if [ -z "${CA_CERT_URL}" ]; then
  echo "CA_CERT_URL not set — skipping CA install."
  exit 0
fi

tmp="$(mktemp)"
trap 'rm -f "${tmp}"' EXIT

echo "Fetching CA from ${CA_CERT_URL} ..."
curl -sk "${CA_CERT_URL}" -o "${tmp}"
grep -q "BEGIN CERTIFICATE" "${tmp}" || { echo "ERROR: no PEM certificate from ${CA_CERT_URL}" >&2; exit 1; }

# shellcheck disable=SC1091
. /etc/os-release 2>/dev/null || true
case "${ID:-}-${ID_LIKE:-}" in
  *debian*|*ubuntu*)
    sudo install -D -m 0644 "${tmp}" "/usr/local/share/ca-certificates/${CA_CERT_NAME%.crt}.crt"
    sudo update-ca-certificates
    ;;
  *suse*|*sles*)
    sudo install -D -m 0644 "${tmp}" "/etc/pki/trust/anchors/${CA_CERT_NAME}"
    sudo update-ca-certificates
    ;;
  *rhel*|*fedora*|*centos*|*rocky*)
    sudo install -D -m 0644 "${tmp}" "/etc/pki/ca-trust/source/anchors/${CA_CERT_NAME}"
    sudo update-ca-trust extract
    ;;
  *)
    echo "ERROR: unrecognized distro (ID=${ID:-?}, ID_LIKE=${ID_LIKE:-?}); cannot place CA" >&2
    exit 1
    ;;
esac

echo "Installed CA ${CA_CERT_NAME} and refreshed the system trust store."

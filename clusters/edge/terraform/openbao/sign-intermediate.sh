#!/usr/bin/env bash
# Creates the intermediate "(openbao)" under the persistent edge root CA:
#   1. OpenBao generates the key and a CSR (generate/internal: the key never
#      leaves OpenBao),
#   2. the CSR is signed HERE with the root key from
#      secrets/edge/root-ca.enc.yaml (decrypted into a 0700 temp dir, shredded),
#   3. the signed certificate + root are imported (intermediate/set-signed).
#
# Run once per install, after `terraform apply` has created the pki mount.
# On a reinstall OpenBao's raft data is gone: run it again. The new intermediate
# chains to the SAME root, so devices keep trusting it.
#
#   OPENBAO_ADDR=https://openbao.<domain> ./sign-intermediate.sh
#
# Logs in as the userpass user `terraform` (PKI only) with the password from
# secrets/edge/app-values.enc.yaml (OPENBAO_TERRAFORM_PASSWORD). OPENBAO_TOKEN,
# if set, is used instead (e.g. an admin token).
set -euo pipefail

: "${OPENBAO_ADDR:?set OPENBAO_ADDR}"
REPO=$(git rev-parse --show-toplevel)
CA="${REPO}/clusters/edge/edge-root-ca.crt"
if [ -z "${OPENBAO_TOKEN:-}" ]; then
  OPENBAO_TOKEN=$(sops -d --extract '["stringData"]["OPENBAO_TERRAFORM_PASSWORD"]' "${REPO}/secrets/edge/app-values.enc.yaml" \
    | jq -Rs '{password: rtrimstr("\n")}' \
    | curl -sS --fail-with-body --cacert "${CA}" -X POST -H 'Content-Type: application/json' --data @- \
        "${OPENBAO_ADDR}/v1/auth/userpass/login/terraform" \
    | jq -r '.auth.client_token')
fi
ROOT_BUNDLE="${REPO}/secrets/edge/root-ca.enc.yaml"
MOUNT=${MOUNT:-pki}
DAYS=${DAYS:-1826}  # 5 years, the mount's max_lease_ttl

umask 077
WORK=$(mktemp -d)
cleanup() { find "${WORK}" -type f -exec shred -u {} + 2>/dev/null || true; rm -rf "${WORK}"; }
trap cleanup EXIT

api() { # method path [json]
  curl -sS --fail-with-body --cacert "${CA}" -X "$1" \
    -H "X-Vault-Token: ${OPENBAO_TOKEN}" -H 'Content-Type: application/json' \
    ${3:+--data "$3"} "${OPENBAO_ADDR}/v1/$2"
}

# REFUSE TO REPLACE A WORKING INTERMEDIATE -- fail closed. LIST, not GET: a
# GET on pki/issuers is "405 unsupported operation", which the first version
# of this check read as "no issuers" and went on (2026-10-05: a second
# intermediate was created next to the working one). An empty mount answers
# LIST with 404 and {"errors":[]}; anything else that is not a list aborts.
issuers=$(curl -sS --cacert "${CA}" -X LIST -H "X-Vault-Token: ${OPENBAO_TOKEN}" \
  -w '\n%{http_code}' "${OPENBAO_ADDR}/v1/${MOUNT}/issuers")
case "${issuers##*$'\n'}" in
  200)
    echo "${MOUNT} already has an issuer -- not creating a second one." >&2
    echo "Rotate on purpose: read the README, then delete the old issuer first." >&2
    exit 1 ;;
  404) ;;  # no issuer yet
  *)
    echo "cannot list ${MOUNT}/issuers (HTTP ${issuers##*$'\n'}) -- refusing to go on" >&2
    exit 1 ;;
esac

echo "1/3 CSR from OpenBao (key generated inside, EC P-256)"
api POST "${MOUNT}/intermediate/generate/internal" \
  '{"common_name":"stuttgart-things edge intermediate CA (openbao)","organization":"stuttgart-things","key_type":"ec","key_bits":256}' \
  | jq -r '.data.csr' > "${WORK}/int.csr"
openssl req -in "${WORK}/int.csr" -noout -verify >/dev/null

echo "2/3 sign with the edge root (offline key from ${ROOT_BUNDLE##*/})"
sops -d --extract '["stringData"]["root.key"]' "${ROOT_BUNDLE}" > "${WORK}/root.key"
sops -d --extract '["stringData"]["root.crt"]' "${ROOT_BUNDLE}" > "${WORK}/root.crt"
cmp -s <(openssl x509 -in "${WORK}/root.crt" -noout -fingerprint -sha256) \
       <(openssl x509 -in "${CA}" -noout -fingerprint -sha256) \
  || { echo "root in ${ROOT_BUNDLE##*/} differs from ${CA##*/}" >&2; exit 1; }
cat > "${WORK}/ext.cnf" <<'CNF'
[v3_int]
basicConstraints=critical,CA:TRUE,pathlen:0
keyUsage=critical,keyCertSign,cRLSign,digitalSignature
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid:always
CNF
openssl x509 -req -in "${WORK}/int.csr" -CA "${WORK}/root.crt" -CAkey "${WORK}/root.key" \
  -CAcreateserial -CAserial "${WORK}/root.srl" -sha384 -days "${DAYS}" \
  -extfile "${WORK}/ext.cnf" -extensions v3_int -out "${WORK}/int.crt" 2>/dev/null
openssl verify -CAfile "${CA}" "${WORK}/int.crt"
shred -u "${WORK}/root.key"

echo "3/3 import into OpenBao"
cat "${WORK}/int.crt" "${CA}" > "${WORK}/chain.pem"
api POST "${MOUNT}/intermediate/set-signed" "$(jq -n --rawfile c "${WORK}/chain.pem" '{certificate: $c}')" \
  | jq '.data | {imported_issuers, imported_keys}'
api GET "${MOUNT}/issuer/default" | jq -r '.data | "default issuer: \(.issuer_name // .issuer_id)  ca_chain: \(.ca_chain | length) certs"'
openssl x509 -in "${WORK}/int.crt" -noout -subject -issuer -enddate

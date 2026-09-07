#!/usr/bin/env bash
# One-time state migration for the change that moved the PKI resources out of
# vault-base-setup and into ./pki.tf.
#
# Terraform sees `pki_enabled = false` as "destroy the module's four PKI
# resources" and the new local blocks as "create four PKI resources" — against
# the same live objects. Running `apply` without this script would tear down the
# mount (and with it the rescued CA) and build it again empty.
#
# So: detach them from the module addresses, re-attach them at the new ones.
# Nothing is created or destroyed in OpenBao; only the state file changes.
#
# The root cert is deliberately NOT migrated. It is not in the new config, it
# does not support import, and the CA behind it is hand-managed on purpose.
#
# Idempotent: skips whatever has already moved.
set -uo pipefail

DIR="${DIR:-$(cd "$(dirname "$0")" && pwd)}"
ENCFILE="${ENCFILE:-$HOME/openbao-init.json.enc}"
ADDR="${VAULT_ADDR:-https://openbao.platform.sthings.lab}"
EXPECT_FP="4E:3F:AD:1D:DD:40:42:62:5F:63:A8:F1:66:9A:3F:1C:9D:65:96:DA:18:EC:BD:77:AF:5B:D5:DD:6D:3D:51:9E"

say()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '  \033[32mok\033[0m   %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; exit 1; }
info() { printf '       %s\n' "$*"; }

cd "$DIR" || bad "$DIR nicht gefunden"

say "0. Vorbedingungen"
export VAULT_ADDR="$ADDR"
export VAULT_TOKEN="${VAULT_TOKEN:-$(sops --decrypt --input-type binary --output-type binary "$ENCFILE" 2>/dev/null \
  | python3 -c "import json,sys;print(json.load(sys.stdin)['root_token'])" 2>/dev/null)}"
[ -n "${VAULT_TOKEN:-}" ] || bad "kein VAULT_TOKEN (weder gesetzt noch aus $ENCFILE lesbar)"
ok "Token vorhanden"

# Refuse to touch anything unless the live CA is the rescued one.
FP=$(curl -s "$ADDR/v1/pki/ca/pem" | openssl x509 -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2)
[ "$FP" = "$EXPECT_FP" ] || { info "erhalten: ${FP:-nichts}"; bad "Live-CA ist nicht der gerettete Root"; }
ok "Live-CA ist der gerettete Root"

say "1. Backup des States"
cp -f terraform.tfstate "terraform.tfstate.pre-pki-migration" 2>/dev/null || true
terraform state pull > "state-backup-$(date +%Y%m%d-%H%M%S).json" 2>/dev/null \
  && ok "State gesichert nach $DIR/state-backup-*.json" \
  || info "state pull nicht moeglich — weiter, aber ohne Netz"

say "2. Aus den Modul-Adressen loesen"
for a in \
  'module.openbao-base-setup.vault_mount.pki[0]' \
  'module.openbao-base-setup.vault_pki_secret_backend_config_urls.urls[0]' \
  'module.openbao-base-setup.vault_pki_secret_backend_role.roles["sthings-lab"]' \
  'module.openbao-base-setup.vault_policy.pki[0]'
do
  if terraform state list 2>/dev/null | grep -qxF "$a"; then
    terraform state rm "$a" >/dev/null 2>&1 && ok "entfernt: $a" || bad "state rm fehlgeschlagen: $a"
  else
    info "nicht im State (schon migriert): $a"
  fi
done

say "3. An den neuen Adressen aufnehmen"
imp() {  # addr, id
  if terraform state list 2>/dev/null | grep -qxF "$1"; then
    info "schon vorhanden: $1"; return 0
  fi
  out=$(terraform import "$1" "$2" 2>&1)
  printf '%s' "$out" | grep -qi 'Import successful' \
    && ok "importiert: $1" \
    || { printf '%s\n' "$out" | grep -iE 'error' | head -3 | sed 's/^/       /'; bad "Import fehlgeschlagen: $1"; }
}
imp 'vault_mount.pki'                          'pki'
imp 'vault_pki_secret_backend_config_urls.urls' 'pki/config/urls'
imp 'vault_pki_secret_backend_role.sthings_lab' 'pki/roles/sthings-lab'
imp 'vault_policy.pki_issue'                    'pki-issue'

say "4. Plan pruefen"
plan=$(terraform plan -no-color 2>&1)
if printf '%s' "$plan" | grep -qE 'will be destroyed|root_cert.*will be created'; then
  bad "Plan will zerstoeren oder einen Root anlegen — NICHT applyen"
fi
ok "keine Zerstoerung, kein Root-Cert"
printf '%s\n' "$plan" | grep -E '^Plan:|No changes' | sed 's/^/       /'

say "Ergebnis"
cat <<'EOF'
  Die PKI-Ressourcen haengen jetzt an den lokalen Adressen; der CA ist keine
  Terraform-Ressource mehr.

  Bleibt im Plan nur die max_ttl-Angleichung (31536000 -> 8760h), ist das
  derselbe Wert in anderer Schreibweise — ein apply davon ist harmlos.

  Danach kann dieses Skript geloescht werden; es ist eine Einmal-Migration.
EOF

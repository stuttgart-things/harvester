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
# OUTSIDE the repo, deliberately. A Terraform state is not a config file: this
# one carries the vault-auth-reviewer JWT among other things, and .gitignore
# covers *.tfstate but would not have caught a state-backup-*.json sitting next
# to the .tf files. Writing it here removes the chance entirely.
BACKUP_DIR="${BACKUP_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/openbao-tfstate-XXXXXX")}"
chmod 700 "$BACKUP_DIR"
BACKUP="$BACKUP_DIR/state-$(date +%Y%m%d-%H%M%S).json"
if terraform state pull > "$BACKUP" 2>/dev/null && [ -s "$BACKUP" ]; then
  chmod 600 "$BACKUP"; ok "State gesichert: $BACKUP"
else
  bad "state pull fehlgeschlagen — ohne Backup wird hier nichts verschoben"
fi

say "2. Ressourcen umhaengen"
# `state mv`, NOT rm + import.
#
# terraform import runs a plan first, and this module cannot be planned from a
# cold start: vault_approle_auth_backend_role_secret_id does for_each over a
# RESOURCE (vault_approle_auth_backend_role.approle) rather than a variable, so
# the keys are "known only after apply" and import aborts with
#
#   Error: Invalid for_each argument
#
# state mv is a pure state operation — no plan, no provider calls — so it walks
# straight past that. It is also the right verb: nothing is being adopted, the
# same object is just moving address.
mv() {
  if terraform state list 2>/dev/null | grep -qxF "$2"; then
    info "schon an neuer Adresse: $2"; return 0
  fi
  if ! terraform state list 2>/dev/null | grep -qxF "$1"; then
    bad "Quelle fehlt im State: $1 — Backup einspielen (siehe README)"
  fi
  terraform state mv "$1" "$2" >/dev/null 2>&1 \
    && ok "$1 -> $2" \
    || bad "state mv fehlgeschlagen: $1"
}
mv 'module.openbao-base-setup.vault_mount.pki[0]'                            'vault_mount.pki'
mv 'module.openbao-base-setup.vault_pki_secret_backend_config_urls.urls[0]'  'vault_pki_secret_backend_config_urls.urls'
mv 'module.openbao-base-setup.vault_pki_secret_backend_role.roles["sthings-lab"]' 'vault_pki_secret_backend_role.sthings_lab'
mv 'module.openbao-base-setup.vault_policy.pki[0]'                           'vault_policy.pki_issue'

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

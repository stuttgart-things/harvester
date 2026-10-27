provider "zitadel" {
  domain = var.zitadel_domain
  # Intentionally omit `port`: passing 443 explicitly makes the provider
  # expect issuer "https://<domain>:443" while ZITADEL's discovery doc
  # reports "https://<domain>" (no port) → "issuer does not match".
  # No `insecure` either: it means plain http, not "skip TLS verify". The
  # OpenBao PKI CA comes in through SSL_CERT_FILE (README).
  jwt_profile_file = var.zitadel_jwt_profile_file
}

# The module of the vSphere labs (stuttgart-things/stuttgart-things#4118),
# pinned to a commit: a change there must not reach this instance unreviewed.
module "zitadel_portal" {
  source = "git::https://github.com/stuttgart-things/stuttgart-things.git//terraform/modules/zitadel-portal?ref=b4ca5fbccb18352675479680478204eef59a22d9"

  zitadel_domain         = var.zitadel_domain
  org_id                 = var.org_id
  portals                = var.portals
  users                  = var.users
  user_initial_passwords = var.user_initial_passwords
}

# OIDC login against ZITADEL (harvester#693 step 4, #574). Client: app
# "harbor" of ../zitadel-config (apps.auto.tfvars); ZITADEL's role check lets
# in only users with harbor-admin or harbor-user.
#
# No oidc_groups_claim / oidc_admin_group: Harbor reads groups only from a
# flat list claim, ZITADEL sends a role map. harbor-admin users are made
# sysadmin once after their first login (README.md, "Admins").
#
# The local admin keeps working (primary_auth_mode = false: the login page
# keeps the local form next to "LOGIN WITH ZITADEL").
#
# The client secret is write-only: it never lands in the state. Bump
# oidc_client_secret_version to push a new one.

variable "zitadel_issuer" {
  type    = string
  default = "https://zitadel.platform.sthings.lab"
}

variable "oidc_client_id" {
  description = "zitadel-config output app_client_ids[\"harbor\"]."
  type        = string
}

variable "oidc_client_secret" {
  description = "zitadel-config output app_client_secrets[\"harbor\"]."
  type        = string
  sensitive   = true
  ephemeral   = true
}

variable "oidc_client_secret_version" {
  type    = number
  default = 1
}

resource "harbor_config_auth" "oidc" {
  auth_mode                     = "oidc_auth"
  primary_auth_mode             = false
  oidc_name                     = "ZITADEL"
  oidc_endpoint                 = var.zitadel_issuer
  oidc_client_id                = var.oidc_client_id
  oidc_client_secret_wo         = var.oidc_client_secret
  oidc_client_secret_wo_version = var.oidc_client_secret_version
  oidc_scope                    = "openid,profile,email"
  oidc_user_claim               = "preferred_username"
  oidc_verify_cert              = true
  oidc_auto_onboard             = true
}

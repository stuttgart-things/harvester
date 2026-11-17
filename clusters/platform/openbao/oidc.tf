# Personal login via ZITADEL OIDC (harvester#719 step 1, stuttgart-things#4605).
# The ZITADEL side (project `vault`, roles vault-admin / vault-reader, the web
# app openbao-platform) is module.vault in ../zitadel-config. The OpenBao side
# is the shared module vault-oidc-zitadel, the same as on LabUL/LabDA.
#
# For PEOPLE only: machines keep their Kubernetes auth / AppRole. The ROOT
# TOKEN stays the break-glass login (this instance has no userpass) -- if
# ZITADEL is down, use the root token (README).
#
# UI login only: method OIDC, role admin or reader. ZITADEL registers only the
# UI callback (no dev_mode), so `bao login -method=oidc` from a shell does not
# work -- copy the token from the UI instead.
#
# Inputs from the ZITADEL root (never in a file):
#   cd ../zitadel-config
#   export TF_VAR_oidc_client_id=$(terraform output -json vault_client_ids | jq -r '."openbao-platform"')
#   export TF_VAR_oidc_client_secret=$(terraform output -json vault_client_secrets | jq -r '."openbao-platform"')
#   export TF_VAR_zitadel_org_id=$(terraform output -raw org_id)

variable "zitadel_issuer" {
  type        = string
  description = "ZITADEL issuer (discovery at <issuer>/.well-known/openid-configuration)."
  default     = "https://zitadel.platform.sthings.lab"
}

variable "oidc_client_id" {
  type        = string
  description = "ZITADEL client ID of the app openbao-platform (zitadel-config output vault_client_ids)."
}

variable "oidc_client_secret" {
  type        = string
  sensitive   = true
  description = "ZITADEL client secret of the app openbao-platform (zitadel-config output vault_client_secrets)."
}

variable "zitadel_org_id" {
  type        = string
  description = "ZITADEL organization ID (zitadel-config output org_id): the key under each role in the roles claim."
}

# What an OIDC admin may do: everything EXCEPT sudo-protected paths (enable /
# disable auth methods and mounts, generate-root, ...). Same idea as LabDA's
# `superuser`: those stay with the root token, so a stolen ZITADEL session
# cannot unmount cert-manager's Kubernetes auth.
resource "vault_policy" "oidc_admin" {
  name   = "oidc-admin"
  policy = <<-EOT
    path "*" {
      capabilities = ["create", "read", "update", "patch", "delete", "list"]
    }
  EOT
}

module "oidc" {
  source = "git::https://github.com/stuttgart-things/stuttgart-things.git//terraform/modules/vault-oidc-zitadel?ref=4ef9a58ff725c355d966febcc80f0b720bdafad5"

  description      = "ZITADEL (zitadel.platform.sthings.lab) personal login, harvester#719"
  issuer           = var.zitadel_issuer
  discovery_ca_pem = file("${path.module}/sthings-lab-root-ca.pem") # CN=sthings.lab, valid to 2036-08-30
  client_id        = var.oidc_client_id
  client_secret    = var.oidc_client_secret
  org_id           = var.zitadel_org_id
  ui_url           = "https://openbao.platform.sthings.lab"
  roles = {
    admin = {
      zitadel_role = "vault-admin"
      policies     = [vault_policy.oidc_admin.name]
    }
    reader = {
      zitadel_role = "vault-reader"
      policies     = ["vault-reader"]
    }
  }
}

variable "zitadel_domain" {
  type        = string
  description = "ZITADEL FQDN on platform (ZITADEL_DOMAIN of the apps-platform zitadel component)."
  default     = "zitadel.platform.sthings.lab"
}

variable "zitadel_jwt_profile_file" {
  type        = string
  description = "Path to the JSON key of the bootstrap machine user `terraform` (Secret `terraform`, key `terraform.json`, namespace zitadel). Pass via TF_VAR_zitadel_jwt_profile_file."
}

variable "org_id" {
  type        = string
  description = "Organization ID. null (default): the module looks up the default org `ZITADEL` by name."
  default     = null
}

variable "portals" {
  type        = map(string)
  description = "Portal deployments that get an OIDC client: name => https base URL."
  default = {
    "homerun2-dev" = "https://portal.homerun2-dev.sthings.lab"
  }
}

variable "users" {
  type = map(object({
    email      = string
    first_name = string
    last_name  = string
    roles      = list(string)
  }))
  description = "Optional human users, user_name => profile + roles (portal-admin, portal-user). Set in users.auto.tfvars."
  default     = {}
}

variable "user_initial_passwords" {
  type        = map(string)
  description = "Optional initial passwords, user_name => password; write-only (never in the state), changed at the first login. Pass via TF_VAR_user_initial_passwords."
  default     = {}
  sensitive   = true
}

variable "apps" {
  type = map(object({
    url               = string
    redirect_paths    = list(string)
    post_logout_paths = optional(list(string), [])
    roles             = map(string)                     # role key => display name
    users             = optional(map(list(string)), {}) # user name (var.users) => role keys
  }))
  description = "OIDC clients next to the portal (apps.tf), app name => base URL, redirect paths, roles and who has which. Set in apps.auto.tfvars."
  default     = {}
}

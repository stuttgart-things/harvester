# Identical in both lab roots (#4612). Lab values are in lab.auto.tfvars and
# users.auto.tfvars; the lab-specific variables have no default on purpose,
# so a run without lab.auto.tfvars fails instead of planning to delete apps.

variable "zitadel_domain" {
  type        = string
  description = "ZITADEL FQDN (ZITADEL_DOMAIN of the apps-platform zitadel component). lab.auto.tfvars."
}

variable "zitadel_jwt_profile_file" {
  type        = string
  description = "Path to the JSON key of the bootstrap machine user `terraform` (Secret `terraform`, key `terraform.json`, namespace zitadel). Pass via TF_VAR_zitadel_jwt_profile_file."
}

variable "org_id" {
  type        = string
  description = "Organization ID. null (default): look up the default org `ZITADEL` by name."
  default     = null
}

# --- users (users.auto.tfvars) ---------------------------------------------

variable "users" {
  type = map(object({
    email      = string
    first_name = string
    last_name  = string
    roles      = list(string)
  }))
  description = "Human users, user_name => profile + sthings-portal roles (portal-admin, portal-user). users.auto.tfvars -- a run without it deletes every user."
}

variable "user_initial_passwords" {
  type        = map(string)
  description = "Optional initial passwords, user_name => password; write-only (never in the state), changed at the first login. Pass via TF_VAR_user_initial_passwords."
  default     = {}
  sensitive   = true
}

# --- sthings-portal project ------------------------------------------------

variable "portal_project_roles" {
  type        = map(string)
  description = "sthings-portal project roles, role_key => display name. The portal matches AUTH_OIDC_ALLOWED_GROUPS against the keys."
  default = {
    "portal-admin" = "Portal Admin"
    "portal-user"  = "Portal User"
  }
}

variable "portals" {
  type        = map(string)
  description = "sthings-portal deployments that get a client in the sthings-portal project: name => https base URL. Redirect <url>/auth/callback, post-logout <url>/auth/login. lab.auto.tfvars."

  validation {
    condition     = alltrue([for url in values(var.portals) : can(regex("^https://[^/]+/?$", url))])
    error_message = "Each portal URL must be https://<host> (no path): ZITADEL rejects http redirects outside dev_mode."
  }
}

variable "oidc_apps" {
  type = map(object({
    redirect_uris             = list(string)
    post_logout_redirect_uris = optional(list(string), [])
  }))
  description = "Clients in the sthings-portal project that are not portals (e.g. Headlamp): name => explicit redirect URIs. Names must not collide with var.portals. lab.auto.tfvars."

  validation {
    condition     = alltrue([for app in values(var.oidc_apps) : length(app.redirect_uris) > 0 && alltrue([for uri in concat(app.redirect_uris, app.post_logout_redirect_uris) : can(regex("^https://[^/]+(/.*)?$", uri))])])
    error_message = "Each oidc_apps entry needs at least one redirect URI, and every URI must be https:// (ZITADEL rejects http redirects outside dev_mode)."
  }
}

# --- sthings-backstage project (Backstage + claim-machinery-api) -----------

variable "backstages" {
  type        = map(string)
  description = "Backstage instances that get a client in the sthings-backstage project: name => https base URL. Redirect <url>/api/auth/oidc/handler/frame. lab.auto.tfvars."

  validation {
    condition     = alltrue([for url in values(var.backstages) : can(regex("^https://[^/]+/?$", url))])
    error_message = "Each Backstage URL must be https://<host> (no path): ZITADEL rejects http redirects outside dev_mode."
  }
}

variable "backstage_roles" {
  type        = map(list(string))
  description = "User name (of var.users) => sthings-backstage roles. Users left out cannot sign in to Backstage (nor order through claim-machinery-api). users.auto.tfvars."
  default     = {}
}

variable "backstage_project_roles" {
  type        = map(string)
  description = <<-EOT
    Backstage project roles, role_key => display name. Besides the two base
    roles, sthings-backstage maps by prefix: backstage-beta-<track> ->
    group:default/beta-<track> (a beta tester of one template track),
    backstage-team-<team> -> group:default/<team> (a team that can own orders).
  EOT
  default = {
    "backstage-platform"  = "Backstage Platform"
    "backstage-developer" = "Backstage Developer"
  }
}

variable "claim_machinery_cli_app_name" {
  type        = string
  description = "Name of the native app `claims login` uses (sthings-backstage project)."
  default     = "claims-cli"
}

variable "claim_machinery_machine_users" {
  type = map(object({
    description = string
    roles       = list(string)
  }))
  description = "Machine users for claim-machinery-api orders (client credentials, JWT): user_name => description + sthings-backstage roles. A role in the API's AUTH_ADMIN_ROLES lets the user name any owner. lab.auto.tfvars."
}

variable "claim_machinery_portals" {
  type        = map(string)
  description = "sthings-portals in front of claim-machinery-api that forward the Backstage roles (#4380): app name => https base URL. Clients of the sthings-backstage project; login needs a Backstage role. lab.auto.tfvars."

  validation {
    condition     = alltrue([for url in values(var.claim_machinery_portals) : can(regex("^https://[^/]+/?$", url))])
    error_message = "Each portal URL must be https://<host> (no path): ZITADEL rejects http redirects outside dev_mode."
  }
}

# --- vault project ---------------------------------------------------------

variable "vaults" {
  type        = map(string)
  description = "Vaults that get a client in the vault project (#4605): name => https base URL incl. port. Empty: no vault project in this lab. lab.auto.tfvars."

  validation {
    condition     = alltrue([for url in values(var.vaults) : can(regex("^https://[^/]+/?$", url))])
    error_message = "Each Vault URL must be https://<host>[:port] (no path): ZITADEL rejects http redirects outside dev_mode."
  }
}

variable "vault_project_roles" {
  type        = map(string)
  description = "vault project roles, role_key => display name. Each key needs a matching Vault OIDC role (vault-vsphere terraform: oidc_roles)."
  default = {
    "vault-admin"  = "Vault Admin"
    "vault-reader" = "Vault Reader"
  }
}

variable "vault_roles" {
  type        = map(list(string))
  description = "User name (of var.users) => vault roles: vault-admin (policy superuser) or vault-reader. Users left out cannot sign in to Vault via OIDC. users.auto.tfvars."
  default     = {}
}

# --- argocd project --------------------------------------------------------

variable "argocds" {
  type        = map(string)
  description = "Argo CD instances that get a client in the argocd project (#4595, #4596): name => https base URL. Redirect <url>/auth/callback. Empty: no argocd project in this lab. lab.auto.tfvars."

  validation {
    condition     = alltrue([for url in values(var.argocds) : can(regex("^https://[^/]+/?$", url))])
    error_message = "Each Argo CD URL must be https://<host> (no path): ZITADEL rejects http redirects outside dev_mode."
  }
}

variable "argocd_project_roles" {
  type        = map(string)
  description = "argocd project roles, role_key => display name. The argo-cd-oidc component maps argocd-admin -> role:admin and argocd-reader -> role:readonly (argocd-rbac-cm)."
  default = {
    "argocd-admin"  = "Argo CD Admin"
    "argocd-reader" = "Argo CD Reader"
  }
}

variable "argocd_roles" {
  type        = map(list(string))
  description = "User name (of var.users) => argocd roles: argocd-admin or argocd-reader. Users left out cannot sign in to Argo CD via OIDC. users.auto.tfvars."
  default     = {}
}

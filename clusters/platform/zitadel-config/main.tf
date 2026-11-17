# Identical in both lab roots (stuttgart-things#4612):
#   LabDA clusters/labda/vsphere/sthings-infra/zitadel-config
#   LabUL clusters/labul/vsphere/infra-sthings/zitadel-portal-config
# main.tf, variables.tf and outputs.tf are the same files; what
# differs per lab is only in lab.auto.tfvars, users.auto.tfvars and
# backend.tf (where the state lives). Keep them in sync: a diff of the two
# directories must show only those three files and the README.

provider "zitadel" {
  domain = var.zitadel_domain
  # Intentionally omit `port`: passing 443 explicitly makes the provider
  # expect issuer "https://<domain>:443" while ZITADEL's discovery doc
  # reports "https://<domain>" (no port) → "issuer does not match".
  # No `insecure` either: it means plain http, not "skip TLS verify". The
  # Vault PKI CA comes in through SSL_CERT_FILE (README).
  jwt_profile_file = var.zitadel_jwt_profile_file
}

locals {
  issuer = "https://${var.zitadel_domain}"

  # Base URLs without a trailing slash, so "<url>/auth/callback" has one.
  portals                 = { for name, url in var.portals : name => trimsuffix(url, "/") }
  backstages              = { for name, url in var.backstages : name => trimsuffix(url, "/") }
  claim_machinery_portals = { for name, url in var.claim_machinery_portals : name => trimsuffix(url, "/") }
  vaults                  = { for name, url in var.vaults : name => trimsuffix(url, "/") }

  # sthings-portal as an OIDC client: code flow, basic auth, groups (roles)
  # and preferred_username read from the ID token (the module defaults).
  portal_apps = {
    for name, url in local.portals : name => {
      redirect_uris             = ["${url}/auth/callback"]
      post_logout_redirect_uris = ["${url}/auth/login"]
    }
  }

  # Clients that are not portals, e.g. Headlamp: the same settings, the
  # redirect URIs as given. Roles and email in the ID token: a kube-apiserver
  # behind Headlamp maps username (email) and groups (roles) from it alone.
  other_apps = {
    for name, app in var.oidc_apps : name => {
      redirect_uris             = app.redirect_uris
      post_logout_redirect_uris = app.post_logout_redirect_uris
    }
  }

  # Backstage's OIDC provider: code flow + refresh, roles and
  # preferred_username in the ID token, where the zitadelProjectRoles
  # resolver reads them (sthings-backstage docs/zitadel.md).
  backstage_apps = {
    for name, url in local.backstages : name => {
      redirect_uris               = ["${url}/api/auth/oidc/handler/frame"]
      post_logout_redirect_uris   = ["${url}/"]
      grant_types                 = ["OIDC_GRANT_TYPE_AUTHORIZATION_CODE", "OIDC_GRANT_TYPE_REFRESH_TOKEN"]
      access_token_role_assertion = true
    }
  }

  # claims CLI login (`claims login`, device authorization flow, claims#98).
  # Public client (no secret), JWT access tokens: claim-machinery-api only
  # verifies JWTs. The loopback redirect is unused by the device flow, but
  # the provider requires one, and it is the only kind ZITADEL allows for
  # native apps.
  claims_cli_app = {
    (var.claim_machinery_cli_app_name) = {
      redirect_uris               = ["http://127.0.0.1/callback"]
      app_type                    = "OIDC_APP_TYPE_NATIVE"
      auth_method_type            = "OIDC_AUTH_METHOD_TYPE_NONE"
      grant_types                 = ["OIDC_GRANT_TYPE_DEVICE_CODE", "OIDC_GRANT_TYPE_REFRESH_TOKEN"]
      access_token_type           = "OIDC_TOKEN_TYPE_JWT"
      access_token_role_assertion = true
    }
  }

  # sthings-portals in front of claim-machinery-api: the portal client
  # settings, but in the sthings-backstage project (see module "backstage").
  claim_machinery_portal_apps = {
    for name, url in local.claim_machinery_portals : name => {
      redirect_uris             = ["${url}/auth/callback"]
      post_logout_redirect_uris = ["${url}/auth/login"]
    }
  }

  # Vault's OIDC auth method reads roles (bound_claims) and
  # preferred_username (user_claim) from the ID token. Only the UI callback:
  # the CLI's http://localhost:8250 would need dev_mode.
  vault_apps = {
    for name, url in local.vaults : name => {
      redirect_uris               = ["${url}/ui/vault/auth/oidc/oidc/callback"]
      post_logout_redirect_uris   = ["${url}/ui/"]
      access_token_role_assertion = true
    }
  }

  # Argo CD's OIDC login (#4595, #4596): argocd-server runs the code flow
  # (confidential client, basic auth) and reads the groups from the ID token.
  # UI only: `argocd login --sso` redirects to http://localhost:8085, which
  # would need dev_mode -- log in in the UI and use `argocd account
  # generate-token` / the session for CLI work.
  argocds = { for name, url in var.argocds : name => trimsuffix(url, "/") }
  argocd_apps = {
    for name, url in local.argocds : name => {
      redirect_uris             = ["${url}/auth/callback"]
      post_logout_redirect_uris = ["${url}/"]
    }
  }

  # Argo CD matches RBAC groups only against a claim that is a string or a
  # list (util/jwt GetScopeValues, checked on v3.6.1). ZITADEL puts the roles
  # into the token as a map (urn:zitadel:iam:org:project:roles), so the action
  # zitadel_action.argocd_roles copies the keys of THIS project's grants into
  # a flat list under this claim.
  argocd_roles_claim = "argocd_roles"

  backstage_app_names = concat(keys(local.backstage_apps), keys(local.claims_cli_app), keys(local.claim_machinery_portal_apps))
}

# Org lookup (default org `ZITADEL`) and the human users of
# users.auto.tfvars. Their roles are granted per project below.
module "users" {
  source = "git::https://github.com/stuttgart-things/stuttgart-things.git//terraform/modules/zitadel-org-users?ref=27555f9a32e58c16fef56546330698b8e6e1ed61"

  org_id                 = var.org_id
  users                  = var.users
  user_initial_passwords = var.user_initial_passwords
}

# sthings-portal login (#4118): project sthings-portal, roles portal-admin /
# portal-user, one client per portal and per oidc_apps entry (Headlamp).
module "portal" {
  source = "git::https://github.com/stuttgart-things/stuttgart-things.git//terraform/modules/zitadel-oidc-project?ref=27555f9a32e58c16fef56546330698b8e6e1ed61"

  org_id       = module.users.org_id
  project_name = "sthings-portal"
  roles        = var.portal_project_roles
  apps         = merge(local.portal_apps, local.other_apps)
  user_ids     = module.users.user_ids
  user_roles   = { for name, u in var.users : name => u.roles }
}

# sthings-backstage login (sthings-backstage#200) and claim-machinery-api
# order auth (#4380). claim-machinery-api has no project of its own: it
# accepts tokens of this project (AUTH_OIDC_AUDIENCE = its ID), because the
# identity-bound parameters map exactly the Backstage roles to groups, so a
# user orders for their team with the roles Backstage shows the order under.
# Hence the claims CLI, the machine users and the portals in front of the API
# are clients / users of this project too: ZITADEL asserts only the roles of
# the client's own project (checked on v4.19.2, #4380).
module "backstage" {
  source = "git::https://github.com/stuttgart-things/stuttgart-things.git//terraform/modules/zitadel-oidc-project?ref=27555f9a32e58c16fef56546330698b8e6e1ed61"

  org_id        = module.users.org_id
  project_name  = "sthings-backstage"
  roles         = var.backstage_project_roles
  apps          = merge(local.backstage_apps, local.claims_cli_app, local.claim_machinery_portal_apps)
  user_ids      = module.users.user_ids
  user_roles    = var.backstage_roles
  machine_users = var.claim_machinery_machine_users
}

# Personal Vault login via OIDC (#4605): project vault, one client per Vault.
# Only where the lab has a Vault entry in var.vaults. The Vault side (auth
# method, roles bound to these role keys) is in the Vault's own root, e.g.
# clusters/labda/vsphere/vault-vsphere/terraform/oidc.tf.
module "vault" {
  source = "git::https://github.com/stuttgart-things/stuttgart-things.git//terraform/modules/zitadel-oidc-project?ref=27555f9a32e58c16fef56546330698b8e6e1ed61"
  count  = length(var.vaults) > 0 ? 1 : 0

  org_id       = module.users.org_id
  project_name = "vault"
  roles        = var.vault_project_roles
  apps         = local.vault_apps
  user_ids     = module.users.user_ids
  user_roles   = var.vault_roles
}

# Argo CD login via OIDC (#4595, #4596): project argocd, one client per Argo
# CD. Only where the lab has an entry in var.argocds. The Argo CD side
# (argocd-cm oidc.config, argocd-rbac-cm) is flux's argo-cd-oidc component,
# switched on in the platform cluster's cicd/platform.yaml.
module "argocd" {
  source = "git::https://github.com/stuttgart-things/stuttgart-things.git//terraform/modules/zitadel-oidc-project?ref=27555f9a32e58c16fef56546330698b8e6e1ed61"
  count  = length(var.argocds) > 0 ? 1 : 0

  org_id       = module.users.org_id
  project_name = "argocd"
  roles        = var.argocd_project_roles
  apps         = local.argocd_apps
  user_ids     = module.users.user_ids
  user_roles   = var.argocd_roles
}

# The flat role list Argo CD's RBAC needs (local.argocd_roles_claim, see
# locals): a ZITADEL action (v1) on "pre userinfo creation" of the token
# flow. It runs for every token of the org, but only adds the claim when the
# user holds roles on the argocd project; other clients ignore an unknown
# claim. With id_token_userinfo_assertion (the module default) the claim is
# in the ID token, where argocd-server reads it.
#
# allowed_to_fail: a broken script must not lock everyone out of every app
# of the org -- the Argo CD login then lacks the claim and RBAC falls back to
# policy.default.
resource "zitadel_action" "argocd_roles" {
  count = length(module.argocd)

  org_id          = module.users.org_id
  name            = "argocdRoles" # must equal the function name
  timeout         = "10s"
  allowed_to_fail = true
  script          = <<-EOT
    function argocdRoles(ctx, api) {
      var grants = ctx.v1.user.grants;
      if (grants == undefined || grants.count == 0) {
        return;
      }
      var roles = [];
      grants.grants.forEach(function (grant) {
        if (grant.projectId !== '${module.argocd[0].project_id}') {
          return;
        }
        grant.roles.forEach(function (role) {
          roles.push(role);
        });
      });
      if (roles.length > 0) {
        api.v1.claims.setClaim('${local.argocd_roles_claim}', roles);
      }
    }
  EOT
}

# ONE resource per org, flow and trigger: it owns the complete action list of
# "pre userinfo creation". Another action for that trigger goes into
# action_ids here, not into a second zitadel_trigger_actions (the two would
# overwrite each other). Before #4596 the trigger had no actions in either lab.
resource "zitadel_trigger_actions" "pre_userinfo" {
  count = length(zitadel_action.argocd_roles)

  org_id       = module.users.org_id
  flow_type    = "FLOW_TYPE_CUSTOMISE_TOKEN"
  trigger_type = "TRIGGER_TYPE_PRE_USERINFO_CREATION"
  action_ids   = [zitadel_action.argocd_roles[0].id]
}

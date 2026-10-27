# Further OIDC clients next to the portal (harvester#574): one project per
# app, so each app has its own roles and ZITADEL refuses a user without a
# role on it (role check) before the app sees a token. The users are the
# module's (users.auto.tfvars); which of them get which role on which app is
# in apps.auto.tfvars.
#
# Every app keeps its local admin (harvester#574, "Grundregel"): these clients
# add a login, they replace none.

locals {
  # Base URL without a trailing slash, as in the module.
  apps = { for name, app in var.apps : name => merge(app, { url = trimsuffix(app.url, "/") }) }

  app_grants = merge([
    for app_name, app in var.apps : {
      for user, roles in app.users : "${app_name}/${user}" => {
        app   = app_name
        user  = user
        roles = roles
      }
    }
  ]...)

  app_unknown_users = setsubtract(flatten([for app in values(var.apps) : keys(app.users)]), keys(var.users))
  app_unknown_roles = flatten([
    for name, app in var.apps : [for r in setsubtract(flatten(values(app.users)), keys(app.roles)) : "${name}/${r}"]
  ])
}

resource "zitadel_project" "app" {
  for_each = local.apps

  org_id                   = module.zitadel_portal.org_id
  name                     = each.key
  project_role_assertion   = true
  project_role_check       = true
  has_project_check        = false
  private_labeling_setting = "PRIVATE_LABELING_SETTING_UNSPECIFIED"

  lifecycle {
    precondition {
      condition     = length(local.app_unknown_users) == 0
      error_message = "var.apps grants roles to users that are not in var.users: ${join(", ", local.app_unknown_users)}"
    }
    precondition {
      condition     = length(local.app_unknown_roles) == 0
      error_message = "var.apps grants roles that the app does not define: ${join(", ", local.app_unknown_roles)}"
    }
  }
}

resource "zitadel_project_role" "app" {
  for_each = merge([
    for name, app in local.apps : {
      for key, display in app.roles : "${name}/${key}" => { app = name, key = key, display = display }
    }
  ]...)

  org_id       = module.zitadel_portal.org_id
  project_id   = zitadel_project.app[each.value.app].id
  role_key     = each.value.key
  display_name = each.value.display
}

# A confidential web client per app (code flow, secret via basic auth), as
# for the portal. Roles and profile claims in the ID token; the flat `groups`
# claim most apps read comes from ./groups-claim.tf.
resource "zitadel_application_oidc" "app" {
  for_each = local.apps

  org_id     = module.zitadel_portal.org_id
  project_id = zitadel_project.app[each.key].id
  name       = each.key

  redirect_uris             = [for p in each.value.redirect_paths : "${each.value.url}${p}"]
  post_logout_redirect_uris = [for p in each.value.post_logout_paths : "${each.value.url}${p}"]

  response_types   = ["OIDC_RESPONSE_TYPE_CODE"]
  grant_types      = ["OIDC_GRANT_TYPE_AUTHORIZATION_CODE"]
  app_type         = "OIDC_APP_TYPE_WEB"
  auth_method_type = "OIDC_AUTH_METHOD_TYPE_BASIC"
  version          = "OIDC_VERSION_1_0"
  dev_mode         = false

  access_token_type           = "OIDC_TOKEN_TYPE_BEARER"
  id_token_role_assertion     = true
  id_token_userinfo_assertion = true
}

resource "zitadel_user_grant" "app" {
  for_each = local.app_grants

  org_id     = module.zitadel_portal.org_id
  project_id = zitadel_project.app[each.value.app].id
  user_id    = module.zitadel_portal.user_ids[each.value.user]
  role_keys  = each.value.roles

  depends_on = [zitadel_project_role.app]
}

# HARVESTER-ONLY: the switch from the old module zitadel-portal (b4ca5fb) to
# the shared root (harvester#680, stuttgart-things#4612). Same resource types
# in the new modules, so the live project, client, users and grants keep their
# IDs -- the homerun2-dev portal's client ID and secret stay valid.
# Can go once every state that knew module.zitadel_portal has been applied
# with these blocks (there is only the one in tfstate-default-zitadel-config).

moved {
  from = module.zitadel_portal.zitadel_human_user.user
  to   = module.users.zitadel_human_user.user
}

moved {
  from = module.zitadel_portal.zitadel_project.portal
  to   = module.portal.zitadel_project.project
}

moved {
  from = module.zitadel_portal.zitadel_project_role.portal
  to   = module.portal.zitadel_project_role.role
}

moved {
  from = module.zitadel_portal.zitadel_application_oidc.portal
  to   = module.portal.zitadel_application_oidc.app
}

moved {
  from = module.zitadel_portal.zitadel_user_grant.user
  to   = module.portal.zitadel_user_grant.user
}

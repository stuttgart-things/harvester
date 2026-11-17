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

# #677: Argo CD moves from harvester-extras.tf (var.apps.argocd, flat groups
# claim) to the shared root's argocd project (var.argocds, claim
# argocd_roles). Same resource types, so project, client (ID + secret) and
# the admins' grants keep their IDs. The role argocd-readonly is replaced by
# the shared root's argocd-reader (role and reader grants are re-created).
moved {
  from = zitadel_project.app["argocd"]
  to   = module.argocd[0].zitadel_project.project
}

moved {
  from = zitadel_application_oidc.app["argocd"]
  to   = module.argocd[0].zitadel_application_oidc.app["argocd"]
}

moved {
  from = zitadel_project_role.app["argocd/argocd-admin"]
  to   = module.argocd[0].zitadel_project_role.role["argocd-admin"]
}

moved {
  from = zitadel_user_grant.app["argocd/sthings"]
  to   = module.argocd[0].zitadel_user_grant.user["sthings"]
}

moved {
  from = zitadel_user_grant.app["argocd/indy"]
  to   = module.argocd[0].zitadel_user_grant.user["indy"]
}

moved {
  from = zitadel_user_grant.app["argocd/tommy"]
  to   = module.argocd[0].zitadel_user_grant.user["tommy"]
}

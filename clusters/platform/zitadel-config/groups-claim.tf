# A flat `groups` claim: every role key the user holds, on any project of the
# org (["portal-admin", "argocd-admin", ...]). ZITADEL itself puts roles into
# urn:zitadel:iam:org:project:roles as an object; ArgoCD, Grafana, MinIO and
# OpenBao want a list of strings. Each app matches only its own role keys, so
# one org-wide claim serves all of them; sthings-portal keeps reading the
# roles claim.
#
# Actions v1 (complement token), ZITADEL's documented recipe for ArgoCD.
# Deprecated in v4 in favour of Actions v2, which need an HTTP target service
# -- revisit before a ZITADEL major upgrade.
#
# The function name must equal the action name.
resource "zitadel_action" "groups_claim" {
  org_id          = module.zitadel_portal.org_id
  name            = "groupsClaim"
  timeout         = "10s"
  allowed_to_fail = true
  script          = <<-EOT
    function groupsClaim(ctx, api) {
      if (ctx.v1.user.grants === undefined || ctx.v1.user.grants.count == 0) {
        return;
      }
      let groups = [];
      ctx.v1.user.grants.grants.forEach(grant => {
        grant.roles.forEach(role => {
          if (groups.indexOf(role) < 0) {
            groups.push(role);
          }
        });
      });
      api.v1.claims.setClaim('groups', groups);
    }
  EOT
}

# Userinfo (and with id_token_userinfo_assertion the ID token) and the access
# token both get it.
resource "zitadel_trigger_actions" "groups_claim" {
  for_each = toset([
    "TRIGGER_TYPE_PRE_USERINFO_CREATION",
    "TRIGGER_TYPE_PRE_ACCESS_TOKEN_CREATION",
  ])

  org_id       = module.zitadel_portal.org_id
  flow_type    = "FLOW_TYPE_CUSTOMISE_TOKEN"
  trigger_type = each.key
  action_ids   = [zitadel_action.groups_claim.id]
}

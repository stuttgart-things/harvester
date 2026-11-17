# Identical in both lab roots (#4612). Names and values are those of the
# roots before the consolidation; consumers read them unchanged.

output "issuer" {
  description = "config.authOidcIssuer / AUTH_OIDC_ISSUER / ZITADEL_ISSUER / oidc_discovery_url / claims login --issuer."
  value       = local.issuer
}

output "org_id" {
  description = "Organization that owns projects, apps and users (Vault: the <orgId> in the bound_claims pointers)."
  value       = module.users.org_id
}

output "user_ids" {
  description = "User name => ZITADEL user ID."
  value       = module.users.user_ids
}

output "project_id" {
  description = "ID of the sthings-portal project."
  value       = module.portal.project_id
}

output "client_ids" {
  description = "Portal / oidc_apps name => client ID (config.authOidcClientId, STHINGS_PORTAL_OIDC_CLIENT_ID)."
  value       = module.portal.client_ids
  sensitive   = true

  precondition {
    condition     = length(setintersection(keys(var.portals), keys(var.oidc_apps))) == 0
    error_message = "oidc_apps and portals share a name; app names are the keys of client_ids / client_secrets."
  }
}

output "client_secrets" {
  description = "Portal / oidc_apps name => client secret (key oidc-client-secret of the portal's auth Secret)."
  value       = module.portal.client_secrets
  sensitive   = true
}

output "backstage_project_id" {
  description = "ID of the sthings-backstage project (zitadelProjectRoles option projectId)."
  value       = module.backstage.project_id
}

output "backstage_client_ids" {
  description = "Backstage name => ZITADEL_CLIENT_ID."
  value       = { for name in keys(var.backstages) : name => module.backstage.client_ids[name] }
  sensitive   = true

  precondition {
    condition     = length(distinct(local.backstage_app_names)) == length(local.backstage_app_names)
    error_message = "backstages, claim_machinery_portals and claim_machinery_cli_app_name share a name; they are apps of the same project."
  }
}

output "backstage_client_secrets" {
  description = "Backstage name => ZITADEL_CLIENT_SECRET."
  value       = { for name in keys(var.backstages) : name => module.backstage.client_secrets[name] }
  sensitive   = true
}

output "claim_machinery_audience" {
  description = "AUTH_OIDC_AUDIENCE of claim-machinery-api (the sthings-backstage project ID)."
  value       = module.backstage.project_id
}

output "claim_machinery_token_url" {
  description = "CLAIM_API_OIDC_TOKEN_URL."
  value       = "${local.issuer}/oauth/v2/token"
}

output "claim_machinery_scope" {
  description = "CLAIM_API_OIDC_SCOPE: puts the project into aud and the roles into the token (claims login adds offline_access)."
  value       = "openid profile urn:zitadel:iam:org:project:id:${module.backstage.project_id}:aud urn:zitadel:iam:org:projects:roles"
}

output "claim_machinery_cli_client_id" {
  description = "claims login --client-id (public client)."
  value       = module.backstage.client_ids[var.claim_machinery_cli_app_name]
  sensitive   = true
}

output "claim_machinery_client_ids" {
  description = "Machine user => CLAIM_API_OIDC_CLIENT_ID."
  value       = module.backstage.machine_client_ids
  sensitive   = true
}

output "claim_machinery_client_secrets" {
  description = "Machine user => CLAIM_API_OIDC_CLIENT_SECRET."
  value       = module.backstage.machine_client_secrets
  sensitive   = true
}

output "claim_machinery_portal_client_ids" {
  description = "Portal app (sthings-backstage project) => STHINGS_PORTAL_OIDC_CLIENT_ID."
  value       = { for name in keys(var.claim_machinery_portals) : name => module.backstage.client_ids[name] }
  sensitive   = true
}

output "claim_machinery_portal_client_secrets" {
  description = "Portal app (sthings-backstage project) => oidc-client-secret of the portal's auth Secret."
  value       = { for name in keys(var.claim_machinery_portals) : name => module.backstage.client_secrets[name] }
  sensitive   = true
}

output "vault_project_id" {
  description = "ID of the vault project (#4605); null without var.vaults."
  value       = one(module.vault[*].project_id)
}

output "vault_client_ids" {
  description = "Vault name => oidc_client_id (vault-vsphere terraform: TF_VAR_oidc_client_id)."
  value       = length(module.vault) > 0 ? module.vault[0].client_ids : {}
  sensitive   = true
}

output "vault_client_secrets" {
  description = "Vault name => oidc_client_secret (vault-vsphere terraform: TF_VAR_oidc_client_secret)."
  value       = length(module.vault) > 0 ? module.vault[0].client_secrets : {}
  sensitive   = true
}

output "argocd_project_id" {
  description = "ID of the argocd project (#4596); null without var.argocds."
  value       = one(module.argocd[*].project_id)
}

output "argocd_client_ids" {
  description = "Argo CD name => client ID (ARGO_CD_OIDC_CLIENT_ID of the argo-cd-oidc component)."
  value       = length(module.argocd) > 0 ? module.argocd[0].client_ids : {}
  sensitive   = true
}

output "argocd_client_secrets" {
  description = "Argo CD name => client secret (key clientSecret of the Secret argocd-oidc-zitadel in the argocd namespace)."
  value       = length(module.argocd) > 0 ? module.argocd[0].client_secrets : {}
  sensitive   = true
}

output "argocd_roles_claim" {
  description = "The ID token claim with the flat argocd role list (argocd-rbac-cm scopes)."
  value       = local.argocd_roles_claim
}

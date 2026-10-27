output "issuer" {
  description = "config.authOidcIssuer / AUTH_OIDC_ISSUER."
  value       = module.zitadel_portal.issuer
}

output "org_id" {
  description = "Organization that owns project, apps and users."
  value       = module.zitadel_portal.org_id
}

output "project_id" {
  description = "ID of the sthings-portal project."
  value       = module.zitadel_portal.project_id
}

output "client_ids" {
  description = "Portal name => config.authOidcClientId."
  value       = module.zitadel_portal.client_ids
  sensitive   = true
}

output "client_secrets" {
  description = "Portal name => key oidc-client-secret of the portal's auth Secret (sthings-portal-auth on homerun2-dev)."
  value       = module.zitadel_portal.client_secrets
  sensitive   = true
}

output "app_client_ids" {
  description = "App name (var.apps) => OIDC client ID."
  value       = { for name, app in zitadel_application_oidc.app : name => app.client_id }
  sensitive   = true
}

output "app_client_secrets" {
  description = "App name (var.apps) => OIDC client secret."
  value       = { for name, app in zitadel_application_oidc.app : name => app.client_secret }
  sensitive   = true
}

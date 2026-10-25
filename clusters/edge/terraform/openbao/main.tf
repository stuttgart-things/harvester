// PKI for the edge node: an intermediate "(openbao)" under the persistent edge
// root (clusters/edge/edge-root-ca.crt) -- the same root the Gateway
// wildcard chains to -- and ACME for device self-enrollment (ESP32).
//
// The intermediate itself is NOT made here: ./sign-intermediate.sh generates
// its key inside OpenBao, signs the CSR offline with the root, and imports
// the certificate. Terraform owns everything around it.

resource "vault_mount" "pki" {
  path        = "pki"
  type        = "pki"
  description = "edge PKI: intermediate (openbao) under the stuttgart-things edge root, ACME"

  default_lease_ttl_seconds = 7776000   // 90 days
  max_lease_ttl_seconds     = 157680000 // 5 years -- the intermediate's own lifetime

  // What ACME clients need to see from the PKI endpoints.
  passthrough_request_headers = ["If-Modified-Since"]
  allowed_response_headers    = ["Last-Modified", "Location", "Replay-Nonce", "Link"]
}

// The mount's own URL: ACME directories and the AIA fields are built from it.
resource "vault_pki_secret_backend_config_cluster" "this" {
  backend  = vault_mount.pki.path
  path     = "${var.openbao_addr}/v1/${vault_mount.pki.path}"
  aia_path = "${var.openbao_addr}/v1/${vault_mount.pki.path}"
}

resource "vault_pki_secret_backend_config_urls" "this" {
  backend                 = vault_mount.pki.path
  enable_templating       = true
  issuing_certificates    = ["{{cluster_aia_path}}/issuer/{{issuer_id}}/der"]
  crl_distribution_points = ["{{cluster_aia_path}}/issuer/{{issuer_id}}/crl/der"]
  depends_on              = [vault_pki_secret_backend_config_cluster.this]
}

// Device certificates. key_type any: ESP32 clients typically send EC keys,
// others RSA -- this role signs what the CSR brings (unlike platform's
// RSA-2048-only signing role).
resource "vault_pki_secret_backend_role" "devices" {
  backend          = vault_mount.pki.path
  name             = "devices"
  allowed_domains  = var.acme_allowed_domains
  allow_subdomains = true
  key_type         = "any"
  server_flag      = true
  client_flag      = true     // mutual TLS from the device side
  ttl              = 7776000  // 90 days
  max_ttl          = 31536000 // 1 year -- seconds, the API returns seconds
  no_store         = false
}

resource "vault_pki_secret_backend_config_acme" "this" {
  backend                  = vault_mount.pki.path
  enabled                  = true
  allowed_roles            = [vault_pki_secret_backend_role.devices.name]
  default_directory_policy = "role:${vault_pki_secret_backend_role.devices.name}"
  eab_policy               = var.acme_eab_policy
  dns_resolver             = var.acme_dns_resolver
  depends_on               = [vault_pki_secret_backend_config_cluster.this]
}

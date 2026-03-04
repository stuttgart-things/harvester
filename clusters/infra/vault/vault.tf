module "vault-base-setup" {
  source          = "github.com/stuttgart-things/vault-base-setup"
  vault_addr      = var.vault_addr
  skip_tls_verify = true
  kubeconfig_path = var.kubeconfig_path
  cluster_name    = var.cluster_name

  csi_enabled = false
  vso_enabled = false

  pki_enabled      = true
  pki_path         = "pki"
  pki_common_name  = var.pki_common_name
  pki_organization = "sva"
  pki_country      = "DE"
  pki_key_type     = "rsa"
  pki_key_bits     = 2048
  pki_root_ttl     = "87600h"

  pki_roles = [
    {
      name             = "sthings-lab"
      allowed_domains  = ["sthings.lab"]
      allow_subdomains = true
      max_ttl          = "8760h"
    }
  ]

  certmanager_vault_issuer_enabled  = true
  certmanager_vault_issuer_pki_role = "sthings-lab"
  certmanager_vault_issuer_server   = "http://vault-server.vault.svc.cluster.local:8200"
}

variable "vault_addr" {
  type        = string
  description = "Vault server address"
  default     = "https://vault.infra.sthings.lab"
}

variable "kubeconfig_path" {
  type        = string
  description = "Path to kubeconfig"
  default     = "/home/sthings/.kube/infra.sthings.lab"
}

variable "cluster_name" {
  type        = string
  description = "Cluster name"
  default     = "infra-sthings"
}

variable "pki_common_name" {
  type        = string
  description = "PKI root CA common name / allowed domain"
  default     = "sthings.lab"
}

output "pki_ca_cert" {
  description = "Root CA certificate"
  value       = module.vault-base-setup.pki_ca_cert
  sensitive   = true
}

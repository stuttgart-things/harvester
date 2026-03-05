module "vault-base-setup" {
  source          = "github.com/stuttgart-things/vault-base-setup"
  vault_addr      = var.vault_addr
  skip_tls_verify = true
  kubeconfig_path = var.kubeconfig_path
  cluster_name    = var.cluster_name

  csi_enabled = false
  vso_enabled = false

  pki_enabled = false

  certmanager_vault_issuer_enabled    = true
  certmanager_vault_issuer_pki_role   = "sthings-lab"
  certmanager_vault_issuer_server     = var.vault_addr
  certmanager_vault_issuer_policy_name = "pki-issue"
}

variable "vault_addr" {
  type        = string
  description = "Vault server address"
  default     = "https://vault.infra.sthings.lab"
}

variable "kubeconfig_path" {
  type        = string
  description = "Path to kubeconfig"
  default     = "/home/sthings/.kube/xplane"
}

variable "cluster_name" {
  type        = string
  description = "Cluster name"
  default     = "xplane-sthings"
}

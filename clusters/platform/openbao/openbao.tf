// OpenBao on the platform cluster — the instance that REPLACES the Vault on
// the infra cluster, which is being switched off to free the hardware.
//
// The module is stuttgart-things/vault-base-setup, which talks to OpenBao
// unchanged: OpenBao is the MPL-2.0 fork of Vault at 1.14, and the
// hashicorp/vault provider speaks that API.
//
// WHAT THIS DOES NOT DO, ON PURPOSE:
//
//   vault_enabled = false           Flux deploys OpenBao (../apps-platform.yaml),
//                                   not this module's Bitnami Vault chart.
//   certmanager_enabled = false     cert-manager is already on this cluster,
//                                   installed by Flux.
//   certmanager_vault_issuer_*      OFF. That path renders a ClusterIssuer with
//                                   a tokenSecretRef — a Vault token created
//                                   here at a 720h default TTL and renewed by
//                                   NOTHING. That is precisely the defect being
//                                   left behind on infra: the token dies at day
//                                   30, renewals fail silently because the
//                                   issuer still reports Ready, and every
//                                   certificate expires at day 90.
//
// The ClusterIssuer instead comes from Flux, component
// infra/cert-manager/components/vault-issuer, and authenticates with the
// Kubernetes auth backend created below. cert-manager mints a ServiceAccount
// token per request; nothing long-lived is stored anywhere.
module "openbao-base-setup" {
  source          = "github.com/stuttgart-things/vault-base-setup"
  vault_addr      = var.openbao_addr
  skip_tls_verify = true
  kubeconfig_path = var.kubeconfig_path
  cluster_name    = var.cluster_name

  csi_enabled = false
  vso_enabled = false

  vault_enabled                    = false
  certmanager_enabled              = false
  certmanager_vault_issuer_enabled = false

  // ---- PKI: a NEW root, not an intermediate -----------------------------
  // The old sthings.lab root lives in the infra Vault and was created as
  // `internal`, so its key cannot be exported and cannot be carried over. This
  // is a genuinely new CA that happens to share the common name.
  //
  // Consequence, and it is the real work of this migration: NOTHING trusts
  // this CA until it is distributed — Ansible for VMs, Flux/Argo for clusters,
  // across the whole harvester environment. Certificates it signs are valid
  // and rejected everywhere until that lands.
  pki_enabled      = true
  pki_path         = "pki"
  pki_common_name  = var.pki_common_name
  pki_organization = "sva"
  pki_country      = "DE"
  pki_key_type     = "rsa"
  // 4096 rather than the module's 2048 default: this key signs everything in
  // the environment for ten years, and it is generated exactly once.
  pki_key_bits    = 4096
  pki_root_ttl    = "87600h"
  pki_policy_name = "pki-issue"

  pki_roles = [
    {
      name             = "sthings-lab"
      allowed_domains  = ["sthings.lab"]
      allow_subdomains = true
      // One year. The certificates themselves are issued for 90 days by
      // cert-manager (duration: 2160h in the Certificate manifests) and renewed
      // 15 days before expiry — this only has to be the ceiling, not the value.
      max_ttl = "8760h"
    }
  ]

  // ---- Kubernetes auth: the whole point ---------------------------------
  // Creates the auth backend at <cluster_name>-<name>, i.e.
  //   /v1/auth/platform-sthings-certmanager
  // with a role of the same name bound to the ServiceAccount `certmanager` in
  // the cert-manager namespace. Those three names have to match the
  // VAULT_ISSUER_* substitutions on the Flux side exactly — see README.md.
  //
  // The token reviewer is a SEPARATE ServiceAccount (vault-auth-reviewer in
  // kube-system) and not the one that logs in — system:auth-delegator is the
  // right to review any token in the cluster, which cert-manager has no
  // business holding. Requires vault-base-setup#54.
  //
  // CHECK BEFORE THE FIRST APPLY, or it fails with
  // `serviceaccounts "vault-auth-reviewer" already exists`:
  //
  //   kubectl -n kube-system get sa vault-auth-reviewer
  //
  // If it is there — the VM pipeline's CreateVaultKubernetesAuth creates one
  // under exactly these names — add `k8s_auth_reviewer_create = false` and the
  // module will read it instead of fighting the pipeline for it. This cluster
  // is built by Ansible rather than that pipeline, so it should not be, but
  // that is worth a look rather than an assumption.
  //
  // token_ttl is the login token cert-manager gets per request. Short is
  // correct: it is re-minted for every signing request.
  k8s_auths = [
    {
      name           = "certmanager"
      namespace      = "cert-manager"
      token_policies = ["pki-issue"]
      token_ttl      = 3600
    }
  ]
}

variable "openbao_addr" {
  type        = string
  description = "OpenBao server address"
  default     = "https://openbao.platform.sthings.lab"
}

variable "kubeconfig_path" {
  type        = string
  description = "Path to kubeconfig"
  default     = "/home/sthings/.kube/platform.sthings.lab"
}

variable "cluster_name" {
  type        = string
  description = "Cluster name. Prefixes the Kubernetes auth mount path."
  default     = "platform-sthings"
}

variable "pki_common_name" {
  type        = string
  description = "PKI root CA common name / allowed domain"
  default     = "sthings.lab"
}

output "pki_ca_cert" {
  description = "Root CA certificate — the one that has to reach every trust store"
  value       = module.openbao-base-setup.pki_ca_cert
  sensitive   = true
}

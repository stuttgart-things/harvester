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

  // ---- PKI: NOT created here any more ----------------------------------
  // The module gates mount, root cert, URLs, role and policy behind this one
  // flag, and the root cert is the one we must not have: this cluster's CA was
  // rescued from raft storage on 2026-09-07 and imported by hand, and it must
  // never pass through Terraform state. The four harmless resources are
  // declared in ./pki.tf instead. Full reasoning there and in ./README.md.
  pki_enabled = false

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


// The CA is no longer produced here, so there is nothing to output. It is not
// Terraform's artefact — it was rescued from raft storage and imported by hand
// (README, "Breaking glass"), and the module output would be empty with
// pki_enabled = false anyway.
//
// To get the certificate for trust-store work, ask the running instance. It is
// public; no token needed:
//
//   curl -s https://openbao.platform.sthings.lab/v1/pki/ca/pem > sthings-lab-ca.crt
//   openssl x509 -in sthings-lab-ca.crt -noout -subject -dates -fingerprint -sha256
//
// The one in use since 2026-09-02 is
//   4E:3F:AD:1D:DD:40:42:62:5F:63:A8:F1:66:9A:3F:1C:9D:65:96:DA:18:EC:BD:77:AF:5B:D5:DD:6D:3D:51:9E

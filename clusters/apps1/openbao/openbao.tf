// Kubernetes auth for THIS cluster against the OpenBao on `platform`.
//
// The PKI lives on platform and is created exactly once, by
// clusters/platform/openbao. This run creates only the half that cannot be
// created from there: an auth mount is configured with THIS cluster's API
// address, CA and reviewer JWT, none of which the platform run can see.
//
//   pki_enabled = false        the mount, the root CA, the signing role and the
//                              pki-issue policy already exist. Recreating them
//                              here would fork the CA.
//   certmanager_*_issuer       off. Unlike platform and xplane, this cluster's
//                              ClusterIssuer comes from the Argo CD
//                              ApplicationSet cert-manager-vault-pki-clusterbook,
//                              configured by annotations on its RancherCluster
//                              XR -- see ../../OPENBAO-CLUSTERBOOK.md.
//
// ORDER MATTERS AND THE FAILURE IS SILENT: clusters/platform/openbao must have
// run first. `pki-issue` is created there, and a role bound to a policy that
// does not exist LOGS IN SUCCESSFULLY and is granted nothing -- so the mistake
// surfaces as a denied signing request much later, not as an error here.
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
  pki_enabled                      = false

  // Creates /v1/auth/apps1-sthings-certmanager, a role of the same name, and the
  // ServiceAccount it admits. All three names have to match the XR annotations
  // vault-k8s-auth-mount / -role / -sa exactly -- change one and all three move.
  //
  // The token reviewer is a SEPARATE ServiceAccount (vault-auth-reviewer in
  // kube-system): system:auth-delegator is the right to review any token in the
  // cluster, which cert-manager has no business holding.
  //
  // k8s_auth_reviewer_create is left at its default, so the module creates the
  // reviewer. NOT verified against this cluster -- it does not exist yet; the
  // sibling directories say "checked" because theirs do. The three existing
  // clusterbook-managed clusters had no vault-auth-reviewer on 2026-09-07, and
  // apps1 is built the same way, so the default is the reasonable assumption
  // rather than a confirmed fact.
  //
  // RUN ../../platform/openbao/preflight.sh, which turns that assumption into a
  // check. If blueprints CreateVaultKubernetesAuth has run against this cluster
  // the apply stops with
  // `serviceaccounts "vault-auth-reviewer" already exists` and needs
  // k8s_auth_reviewer_create = false.
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
  description = "OpenBao server address -- the instance on the platform cluster"
  default     = "https://openbao.platform.sthings.lab"
}

variable "kubeconfig_path" {
  type        = string
  description = "Path to kubeconfig. This cluster ships none by default; see ../../OPENBAO-CLUSTERBOOK.md for deriving one from the Argo CD cluster Secret."
  default     = "/home/sthings/.kube/apps1"
}

variable "cluster_name" {
  type        = string
  description = "Cluster name. Prefixes the Kubernetes auth mount path."
  default     = "apps1-sthings"
}

// The cert-manager Kubernetes auth mount for the `homerun2-dev` cluster, on the
// OpenBao that runs on `platform`. One mount, and that is all this directory
// does.
//
// WHY TERRAFORM AND NOT THE XR PATH. clusters/tabletennis/openbao explains that
// its cert-manager mount moved to `spec.vaultAuth.composeMount` on the
// RancherCluster XR, which derives the mount path and the annotations from one
// value. homerun2-dev has no XR -- it is a hand-built Flux cluster from
// vms/homerun2-dev.params.yaml -- so there is nothing to compose from. A
// standalone VaultK8sAuth XR does not help either: it needs `kubernetesHost`,
// and the composed child only gets that for free from `apiserverIp` in the
// reviewer Secret. Terraform reads it out of the kubeconfig instead
// (vault-base-setup takes clusters[0].cluster.server), so this apply needs no
// hand-edited address.
//
// THE POLICY IS NOT CREATED HERE. `pki-issue` is an object on the OpenBao, made
// by clusters/platform/openbao/pki.tf alongside the pki mount and the
// sthings-lab signing role. It is shared by every cluster's certmanager role.
//
//   A ROLE BOUND TO A POLICY THAT DOES NOT EXIST LOGS IN SUCCESSFULLY AND IS
//   GRANTED NOTHING. The symptom is a ClusterIssuer that reports Ready while no
//   Certificate is ever issued. Confirm the policy is there before applying.
//
// WHAT CONSUMES THIS. infra-platform.yaml selects the cert-manager-vault-issuer
// component, whose VAULT_ISSUER_AUTH_MOUNT_PATH must be
// /v1/auth/homerun2-dev-certmanager -- `<cluster_name>-<k8s_auths[].name>`. The
// mount path, the role and the ServiceAccount move together or not at all.
//
// ORDER: apply this BEFORE the ClusterIssuer exists. cert-manager sets Ready on
// a successful LOGIN and never re-checks the ability to SIGN, so an issuer
// pointed at a mount that does not exist is loud, but an issuer whose role
// grants nothing is silent.
//
//   export VAULT_TOKEN=<a token that may write auth mounts on that OpenBao>
//
//   KUBECONFIG_PATH=/home/sthings/.kube/homerun2-dev \
//     ../../platform/openbao/preflight.sh \
//     && terraform init \
//     && terraform apply
//
// No `provider "kubernetes"` block: the module declares and configures its own
// from `kubeconfig_path`. Same as every sibling openbao root here.
module "openbao-base-setup" {
  // PINNED TO THE COMMIT, NOT TO v1.2.0, AND THE DIFFERENCE IS A PRIVILEGE:
  //
  // In v1.2.0 the ServiceAccount that LOGS IN through a mount is also the one
  // whose JWT Vault presents to TokenReview, so the module grants it
  // `system:auth-delegator` -- the right to review ANY token in the cluster.
  // That would hand it to cert-manager's ServiceAccount here.
  //
  // e5b4544 (vault-base-setup#54) splits the two: a dedicated
  // `vault-auth-reviewer` in kube-system holds auth-delegator, and the login
  // ServiceAccounts hold nothing. No release carries that fix yet.
  //
  // Raise this to the first tag above v1.2.0 once one exists.
  source          = "github.com/stuttgart-things/vault-base-setup?ref=e5b4544ef1d13052e6f41c1ab7ac616de5d38037"
  vault_addr      = var.openbao_addr
  skip_tls_verify = true
  kubeconfig_path = var.kubeconfig_path
  cluster_name    = var.cluster_name

  csi_enabled = false
  vso_enabled = false

  // OpenBao itself, cert-manager and the PKI all exist already -- on platform
  // and on this cluster respectively. This directory adds the auth mount and
  // nothing else.
  vault_enabled                    = false
  certmanager_enabled              = false
  certmanager_vault_issuer_enabled = false
  pki_enabled                      = false

  // k8s_auth_reviewer_create is left at its default, so the module creates the
  // token reviewer. Verified absent before writing this:
  //   kubectl -n kube-system get sa vault-auth-reviewer  -> NotFound
  // If blueprints CreateVaultKubernetesAuth is ever run against this cluster
  // first, the apply stops with `serviceaccounts "vault-auth-reviewer" already
  // exists` and needs k8s_auth_reviewer_create = false. ../../platform/openbao/
  // preflight.sh checks exactly this.
  k8s_auths = [
    {
      name           = "certmanager"
      namespace      = "cert-manager"
      token_policies = ["pki-issue"]
      // The login token cert-manager gets per signing request. Short is right:
      // Kubernetes auth mints one per request through the TokenRequest API and
      // stores nothing long-lived in the cluster.
      token_ttl = 3600

      // Admit cert-manager's OWN ServiceAccount rather than one the module
      // would create and admit. `cert-manager` in `cert-manager` is what the
      // controller actually runs as -- not -cainjector or -webhook, which the
      // same chart also creates. Verified on the cluster before writing this.
      //
      // It must match VAULT_ISSUER_SERVICE_ACCOUNT in infra-platform.yaml. A
      // bound name that does not exist fails the way everything here fails:
      // silently.
      bound_service_account_names      = ["cert-manager"]
      bound_service_account_namespaces = ["cert-manager"]
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
  description = "Path to this cluster's kubeconfig. secrets/homerun2-dev.yaml holds it SOPS-encrypted; see clusters/homerun2-dev/README.md step 3."
  default     = "/home/sthings/.kube/homerun2-dev"
}

variable "cluster_name" {
  type        = string
  description = "Cluster name. Prefixes the Kubernetes auth mount path, giving /v1/auth/homerun2-dev-certmanager."
  default     = "homerun2-dev"
}

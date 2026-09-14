// Kubernetes auth mounts for the `tabletennis` cluster, on the OpenBao that
// runs on `platform`.
//
// ONLY THE PART THAT BELONGS TO THIS CLUSTER. Each mount is configured with
// THIS cluster's API address, CA and reviewer JWT, so it cannot be created
// before the cluster exists and cannot outlive it. Two of them:
//
//   certmanager -- the clusterbook half that cannot be created from
//                  clusters/platform/openbao. Same shape as every other
//                  clusterbook cluster here.
//   eso         -- External Secrets, logging in to read the application
//                  secrets.
//
// THE SECRETS THEMSELVES ARE NOT HERE. The KV mount, its entries and the read
// policy live in ../../platform/openbao/app-secrets, because they are objects
// on the OpenBao rather than on this cluster -- so they survive a teardown and
// rebuild of tabletennis, and a rebuild costs only this apply.
//
// The PKI is not here either: it lives on platform and is created exactly once,
// by clusters/platform/openbao. Recreating it would fork the CA. Nor is the
// ClusterIssuer -- that comes from the Argo CD ApplicationSet
// cert-manager-vault-pki-clusterbook, driven by annotations on the
// RancherCluster XR. See ../../OPENBAO-CLUSTERBOOK.md.
//
// THIS DIRECTORY IS A CANDIDATE TO DISAPPEAR -- see
// stuttgart-things/crossplane-configurations#411. The rancher-cluster
// Composition grew `spec.vaultAuth.composeMount`, which composes a VaultK8sAuth
// that creates the cert-manager mount and DERIVES the four vault-k8s-auth-*
// annotations, so they can no longer drift from the mount. That is strictly
// better than doing it here. Two reasons it is not used yet:
//
//   1. IT IS NOT ON THE CONTROL PLANE. ghcr and crossplane-mgmt both carry
//      rancher-cluster v0.7.1; the repo is at v0.7.2. v0.7.1 predates #392
//      Phase 1 and Phase 2, so `vaultAuth` does not exist there at all -- not
//      even `enabled`. Publishing and upgrading it is blocker 1 of #411, and
//      the composed chain has never been executed against a real cluster.
//      #411 is the ticket that finds out whether it converges on its own.
//
//   2. IT WOULD ONLY COVER HALF OF THIS FILE. The composed block emits exactly
//      ONE k8sAuths entry -- `roleName`, default `certmanager`, bound to the
//      cert-manager ServiceAccount. ESO needs a second mount, and composeMount
//      has no way to add one. A standalone VaultK8sAuth XR could: its
//      k8sAuths[] is a list, and vault-auth v0.3.2 is installed. But it reads
//      the reviewer Secret and kubernetesHost that only `vaultAuth.enabled`
//      produces, so it waits on the same upgrade.
//
// When #411 lands, the replacement for this file is one VaultK8sAuth XR with
// both entries, or composeMount for cert-manager plus a small XR for eso. The
// KV half is unaffected either way -- no XR creates secret engines.
//
// ORDER MATTERS AND BOTH FAILURES ARE SILENT. Two applies must have run first:
//
//   clusters/platform/openbao             creates `pki-issue`
//   clusters/platform/openbao/app-secrets creates `read-tabletennis`
//
// A role bound to a policy that does not exist LOGS IN SUCCESSFULLY and is
// granted nothing. Run these out of order and nothing errors here -- the
// symptom is a denied signing request, or an ExternalSecret that never syncs,
// hours later.
//
// NO `provider "kubernetes"` BLOCK IN THIS ROOT MODULE, deliberately: the
// module declares and configures its own kubernetes/kubectl/helm/vault
// providers from `kubeconfig_path` (see its provider.tf). A root block would be
// a second, unused configuration -- ../../apps1/openbao and every sibling here
// leave it out for the same reason.
module "openbao-base-setup" {
  // PINNED TO THE COMMIT, NOT TO v1.2.0, AND THE DIFFERENCE IS A PRIVILEGE:
  //
  // In v1.2.0 the ServiceAccount that LOGS IN through a mount is also the one
  // whose JWT Vault presents to TokenReview, so the module grants it
  // `system:auth-delegator` -- the right to review ANY token in the cluster.
  // That would hand it to cert-manager's and ESO's ServiceAccounts here.
  //
  // e5b4544 (vault-base-setup#54) splits the two: a dedicated
  // `vault-auth-reviewer` in kube-system holds auth-delegator, and the login
  // ServiceAccounts hold nothing. No release carries that fix yet, and the
  // sibling openbao directories track the branch unpinned to get it. Pinning
  // the commit keeps their behaviour without the moving target.
  //
  // Raise this to the first tag above v1.2.0 once one exists.
  source          = "github.com/stuttgart-things/vault-base-setup?ref=e5b4544ef1d13052e6f41c1ab7ac616de5d38037"
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

  // Mount paths come out as <cluster_name>-<name>, so these two produce
  // /v1/auth/tabletennis-sthings-certmanager and
  // /v1/auth/tabletennis-sthings-eso.
  //
  // BOTH NAMES ARE LOAD-BEARING ELSEWHERE:
  //   certmanager -> the XR annotations vault-k8s-auth-mount / -role / -sa,
  //                  which must match all three exactly;
  //   eso         -> the ClusterSecretStore's auth.kubernetes.mountPath, whose
  //                  convention is <cluster-name>-eso.
  //
  // The module creates the ServiceAccount each mount admits (<name> in
  // <namespace>) unless bound_service_account_names is overridden. The token
  // REVIEWER is a separate ServiceAccount (vault-auth-reviewer in kube-system):
  // system:auth-delegator is the right to review any token in the cluster,
  // which neither cert-manager nor ESO has any business holding.
  //
  // k8s_auth_reviewer_create is left at its default, so the module creates the
  // reviewer. RUN ../../platform/openbao/preflight.sh first -- if blueprints
  // CreateVaultKubernetesAuth has already run against this cluster the apply
  // stops with `serviceaccounts "vault-auth-reviewer" already exists` and needs
  // k8s_auth_reviewer_create = false.
  k8s_auths = [
    {
      name           = "certmanager"
      namespace      = "cert-manager"
      token_policies = ["pki-issue"]
      token_ttl      = 3600
    },
    {
      // External Secrets logs in here and reads the three entries below.
      // token_policies names a policy created in
      // ../../platform/openbao/app-secrets, NOT here -- a role bound to a
      // policy that does not exist logs in fine and is granted nothing, and
      // the symptom is an ExternalSecret that never syncs.
      name           = "eso"
      namespace      = "external-secrets"
      token_policies = ["read-tabletennis"]
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
  default     = "/home/sthings/.kube/tabletennis"
}

variable "cluster_name" {
  type        = string
  description = "Cluster name. Prefixes both Kubernetes auth mount paths."
  default     = "tabletennis-sthings"
}

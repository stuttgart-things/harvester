// The ESO Kubernetes auth mount for the `tabletennis` cluster, on the OpenBao
// that runs on `platform`. One mount, and that is all this directory does.
//
// THE CERT-MANAGER MOUNT USED TO BE HERE AND IS NOT ANY MORE. It comes from
// `spec.vaultAuth.composeMount` on the RancherCluster XR, which also DERIVES the
// four vault-k8s-auth-* annotations from the same values -- so the mount path
// can no longer drift from the annotation naming it. That is strictly better
// than writing it twice, and it was proven end to end on 2026-09-14
// (crossplane-configurations#411).
//
// WHY ESO DID NOT MOVE WITH IT, AND IT IS NOT AN OVERSIGHT:
//
//   1. composeMount emits exactly ONE k8sAuths entry -- `roleName`, bound to the
//      cert-manager ServiceAccount in `cert-manager`. There is no parameter for
//      a second mount.
//
//   2. A separately applied VaultK8sAuth XR could carry both, since its
//      k8sAuths[] is a list. But it needs `kubernetesHost`, and the default
//      (https://kubernetes.default.svc:443) is only meaningful in-cluster --
//      the OpenBao on platform has to reach THIS cluster's API server by its
//      real address. The composed child gets that for free from `apiserverIp`
//      in the reviewer Secret; a static YAML file in git cannot, because the
//      address is not known until the cluster is provisioned. It would have to
//      be filled in by hand afterwards.
//
//      Terraform gets it for free too -- vault-base-setup reads
//      kubeconfig.clusters[0].cluster.server -- so this apply needs no edited
//      file at any point. That is the whole reason this directory survives.
//
// When rancher-cluster grows a list of k8sAuths (the right long-term fix, and
// an upstream change), this directory goes away entirely.
//
// THE SECRETS THEMSELVES ARE NOT HERE. The KV mount, its entries and the
// read-tabletennis policy live in ../../platform/openbao/app-secrets, because
// they are objects on the OpenBao rather than on this cluster -- so they survive
// a teardown and rebuild of tabletennis.
//
// ORDER, AND THE FAILURE IS SILENT: clusters/platform/openbao/app-secrets must
// have run first. The role below is bound to the policy it creates, and a role
// bound to a policy that does not exist LOGS IN SUCCESSFULLY and is granted
// nothing -- the symptom is an ExternalSecret that never syncs, hours later.
//
// No `provider "kubernetes"` block: the module declares and configures its own
// from `kubeconfig_path`. Same as every sibling openbao root here.
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

  // k8s_auth_reviewer_create is left at its default, so the module creates the
  // token reviewer. RUN ../../platform/openbao/preflight.sh first -- if
  // blueprints CreateVaultKubernetesAuth has already run against this cluster
  // the apply stops with `serviceaccounts "vault-auth-reviewer" already exists`
  // and needs k8s_auth_reviewer_create = false.
  //
  // Mount path comes out as <cluster_name>-<name>, i.e.
  // /v1/auth/tabletennis-sthings-eso. The name is load-bearing: the
  // ClusterSecretStore's auth.kubernetes.mountPath must match it, and its
  // convention is <cluster-name>-eso.
  //
  // BOUND TO ESO'S OWN ServiceAccount, NOT TO A NEW ONE. vault-base-setup would
  // create a ServiceAccount named after the mount and admit that -- but nothing
  // else would ever use it, and the ClusterSecretStore would have to name it.
  // `external-secrets` in `external-secrets` is the identity the controller
  // already runs as: the chart is installed with releaseName `external-secrets`
  // and no fullnameOverride or serviceAccount.name
  // (argocd infra/external-secrets/install), so that is the controller's SA --
  // not the -webhook or -cert-controller one, which the same chart also creates.
  //
  // Binding to it removes a ServiceAccount nobody owned and a name that could
  // drift. VERIFY IT ON THE FIRST BUILD before applying --
  // `kubectl -n external-secrets get sa` -- because a bound name that does not
  // exist fails exactly the way everything else here fails: silently.
  //
  // The token reviewer stays a separate ServiceAccount (vault-auth-reviewer in
  // kube-system): system:auth-delegator is the right to review any token in the
  // cluster, which ESO has no business holding.
  k8s_auths = [
    {
      name           = "eso"
      namespace      = "external-secrets"
      token_policies = ["read-tabletennis"]
      token_ttl      = 3600

      // Admit the controller's existing ServiceAccount instead of the one the
      // module would otherwise create and admit.
      bound_service_account_names      = ["external-secrets"]
      bound_service_account_namespaces = ["external-secrets"]
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

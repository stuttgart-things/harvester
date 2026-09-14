// OpenBao setup for the `tabletennis` cluster, against the OpenBao on `platform`.
//
// TWO JOBS IN ONE APPLY, because they share a cluster_name and a kubeconfig:
//
//   1. Kubernetes auth for cert-manager -- the clusterbook half that cannot be
//      created from clusters/platform/openbao, because it is configured with
//      THIS cluster's API address, CA and reviewer JWT. Same shape as
//      ../../apps1/openbao (now removed) and the other clusterbook clusters.
//
//   2. The KV mount and the three application entries the homerun2 and
//      tabletennis platforms read through External Secrets, plus the ESO auth
//      mount and the read policy that let it get at them.
//
// WHAT IS NOT HERE: the PKI. It lives on platform and is created exactly once,
// by clusters/platform/openbao. Recreating it here would fork the CA.
// The ClusterIssuer is not here either -- it comes from the Argo CD
// ApplicationSet cert-manager-vault-pki-clusterbook, driven by annotations on
// the RancherCluster XR. See ../../OPENBAO-CLUSTERBOOK.md.
//
// ORDER MATTERS AND ONE FAILURE IS SILENT: clusters/platform/openbao must have
// run first. `pki-issue` is created there, and a role bound to a policy that
// does not exist LOGS IN SUCCESSFULLY and is granted nothing -- so the mistake
// surfaces as a denied signing request much later, not as an error here.
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
      // token_policies must name the policy from var.kv_policies -- a role
      // bound to a policy that does not exist logs in fine and is granted
      // nothing, and the symptom is an ExternalSecret that never syncs.
      name           = "eso"
      namespace      = "external-secrets"
      token_policies = ["read-tabletennis"]
      token_ttl      = 3600
    }
  ]

  // Both from terraform.tfvars.sops.json -- decrypt it, never hand-edit a
  // plaintext copy into place. See terraform.tfvars.example.json for the shape
  // and README.md for what each property is and who reads it.
  secret_engines = var.secret_engines
  kv_policies    = var.kv_policies
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

variable "secret_engines" {
  type = list(object({
    name        = string
    path        = string
    description = string
    data_json   = string
  }))
  description = "KV v2 mounts and the entries in them. One mount per distinct `path`; one entry per path+name."
  sensitive   = true
}

variable "kv_policies" {
  type = list(object({
    name         = string
    capabilities = string
  }))
  description = "Vault policies. `capabilities` is a whole policy document, not a verb list."
}

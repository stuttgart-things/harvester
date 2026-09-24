// The cert-manager Kubernetes auth mount for the `machinery-hv` cluster, on the
// OpenBao that runs on `platform`. Same shape as ../../homerun2-dev/openbao --
// read the notes there; only the name differs.
//
// ONE MOUNT, ON PURPOSE. What Crossplane on this cluster does to OpenBao (Vault
// auth mounts, kubeconfig entries, app secrets for the clusters it builds) goes
// through provider-vault with AppRoles, not through a Kubernetes auth mount on
// this cluster. Those AppRoles are OpenBao-side objects and belong under
// ../../platform/openbao, not here -- see ../../machinery-hv-fleet-state/README.md.
//
// ORDER: apply this BEFORE the ClusterIssuer exists, and after
// ../../platform/openbao has created the `pki-issue` policy. A role bound to a
// policy that does not exist logs in and is granted nothing.
//
//   export VAULT_TOKEN=<a token that may write auth mounts on that OpenBao>
//
//   KUBECONFIG_PATH=/home/sthings/.kube/machinery-hv \
//     ../../platform/openbao/preflight.sh \
//     && terraform init \
//     && terraform apply
module "openbao-base-setup" {
  // Pinned to the commit, not v1.2.0: e5b4544 keeps system:auth-delegator off
  // cert-manager's ServiceAccount. See ../../homerun2-dev/openbao/openbao.tf.
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

  k8s_auths = [
    {
      name           = "certmanager"
      namespace      = "cert-manager"
      token_policies = ["pki-issue"]
      token_ttl      = 3600

      // Must match VAULT_ISSUER_SERVICE_ACCOUNT in ../infra-platform.yaml.
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
  description = "Path to this cluster's kubeconfig. secrets/machinery-hv.yaml holds it SOPS-encrypted once the cluster exists; see clusters/machinery-hv/README.md step 3."
  default     = "/home/sthings/.kube/machinery-hv"
}

variable "cluster_name" {
  type        = string
  description = "Cluster name. Prefixes the Kubernetes auth mount path, giving /v1/auth/machinery-hv-certmanager."
  default     = "machinery-hv"
}

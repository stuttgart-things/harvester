// Application secrets for WORKLOAD clusters, on the OpenBao that outlives them.
//
// WHY THIS SITS UNDER platform/ AND NOT UNDER THE CLUSTER IT SERVES: the KV
// mount, its entries and the read policy are objects on the OpenBao, which runs
// here. A workload cluster is the shorter-lived thing -- tabletennis may be torn
// down and rebuilt, and when it is, its credentials should still be here rather
// than having to be regenerated and redistributed. Rebuilding the cluster then
// costs one `terraform apply` in its own openbao/ directory (the auth mounts,
// which genuinely die with it) and nothing here.
//
// THE SPLIT IS NOT COSMETIC. What lives beside the cluster is everything
// configured WITH that cluster -- the Kubernetes auth mounts carry its API
// address, CA and reviewer JWT, so they cannot outlive it and cannot be created
// before it exists. Nothing in this directory needs the workload cluster at all,
// so this apply can run first, and should.
//
// ORDER, AND ONE HALF OF IT FAILS SILENTLY:
//
//   1. this directory        -- creates the mount, the entries and the policy
//   2. clusters/<cluster>/openbao -- creates the auth mounts, one of whose roles
//                               is bound to the policy from step 1
//
// A role bound to a policy that does not exist LOGS IN SUCCESSFULLY and is
// granted nothing. Run it the other way round and the symptom is not an error
// but an ExternalSecret that never syncs, hours later.
//
// No `provider "kubernetes"` block: the module declares and configures its own
// from `kubeconfig_path`. Same as every sibling openbao root here.
module "openbao-app-secrets" {
  // Pinned to the commit rather than v1.2.0 for the same reason as
  // ../../../tabletennis/openbao -- see the note there. Nothing in this root
  // touches Kubernetes, so the difference does not bite here, but the two should
  // not drift apart on the same OpenBao.
  source          = "github.com/stuttgart-things/vault-base-setup?ref=e5b4544ef1d13052e6f41c1ab7ac616de5d38037"
  vault_addr      = var.openbao_addr
  skip_tls_verify = true
  kubeconfig_path = var.kubeconfig_path

  // Inert here: cluster_name only prefixes Kubernetes auth mount paths, and this
  // root creates none. It is set rather than left at the module default so a
  // `terraform plan` reads unambiguously.
  cluster_name = "platform-sthings"

  // THIS ROOT CREATES NOTHING IN KUBERNETES. k8s_auths is left empty on purpose:
  // every auth mount belongs to the cluster it authenticates, beside that
  // cluster. The kubeconfig above is required by the module's provider
  // configuration, not used to create anything.
  k8s_auths = []

  csi_enabled = false
  vso_enabled = false

  vault_enabled                    = false
  certmanager_enabled              = false
  certmanager_vault_issuer_enabled = false
  pki_enabled                      = false

  // Both from terraform.tfvars.sops.json -- decrypt it, never hand-edit a
  // plaintext copy into place. README.md has the shape, who reads every
  // property, and the pairs that have to match byte for byte.
  secret_engines = var.secret_engines
  kv_policies    = var.kv_policies
}

variable "openbao_addr" {
  type        = string
  description = "OpenBao server address -- the instance on this cluster"
  default     = "https://openbao.platform.sthings.lab"
}

variable "kubeconfig_path" {
  type        = string
  description = "Path to the platform kubeconfig. Required by the module's provider configuration; this root creates no Kubernetes resources."
  default     = "/home/sthings/.kube/platform.sthings.lab"
}

variable "secret_engines" {
  type = list(object({
    name        = string
    path        = string
    description = string
    data_json   = string
  }))
  description = "KV v2 mounts and the entries in them. One mount per distinct `path`; one entry per path+name. One mount per workload cluster."
  sensitive   = true
}

variable "kv_policies" {
  type = list(object({
    name         = string
    capabilities = string
  }))
  description = "Vault policies. `capabilities` is a whole policy document, not a verb list."
}

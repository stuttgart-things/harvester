// platform's OWN external-secrets login on its OpenBao (harvester#753): the
// Kubernetes auth mount the ClusterSecretStore `vault-kubeconfigs`
// (../../infra.yaml) logs in with, and the one policy it gets -- read the
// `kubeconfigs` mount that ../machinery-fleet owns and machinery-hv's
// ClusterStacks write. clusterscope's live mode reads the lab's other
// clusters through it (../../apps/clusterscope.yaml).
//
// A ROOT OF ITS OWN, like ../machinery-fleet and ../app-secrets: ../openbao.tf
// carries the PKI and the cert-manager mount, and a plan here must never be
// able to touch either.
//
// NO KUBERNETES RESOURCES, NO REVIEWER SERVICEACCOUNT. OpenBao runs IN this
// cluster, so the auth mount reviews ESO's tokens with OpenBao's own pod
// ServiceAccount (`disable_local_ca_jwt = false`, host = the in-cluster API).
// That ServiceAccount already holds system:auth-delegator through the chart
// (ClusterRoleBinding openbao-openbao-server-binding). ESO mints the token it
// logs in with for its own ServiceAccount; the ESO chart grants its controller
// `create serviceaccounts/token` cluster-wide (2.15.0, checked with
// `helm template`).
//
// ORDER: apply this BEFORE the Flux side is merged. A store whose mount does
// not exist reports InvalidProviderConfig and the clusterscope Kustomization
// waits on its ExternalSecret.
//
//   export VAULT_TOKEN=$(cat ~/.vaulttoken)
//   terraform init && terraform apply

terraform {
  required_providers {
    vault = {
      source = "hashicorp/vault"
    }
  }
}

provider "vault" {
  address = var.openbao_addr
  // Same as every sibling root: OpenBao's certificate is issued by its own PKI,
  // which this workstation does not trust.
  skip_tls_verify  = true
  skip_child_token = true
}

// <cluster_name>-<auth name>, the convention every other mount on this
// OpenBao follows (platform-sthings-certmanager, tabletennis-sthings-eso).
resource "vault_auth_backend" "eso" {
  type        = "kubernetes"
  path        = "platform-sthings-eso"
  description = "external-secrets on platform (harvester#753)"
}

resource "vault_kubernetes_auth_backend_config" "eso" {
  backend         = vault_auth_backend.eso.path
  kubernetes_host = "https://kubernetes.default.svc.cluster.local:443"
  // OpenBao's own mounted ServiceAccount token reviews, and its mounted CA
  // verifies, the API -- both re-read from the pod on every login.
  disable_local_ca_jwt = false
}

// `find` (the clusterscope ExternalSecret selects entries by a name regexp)
// LISTs the mount's metadata root, which read-kubeconfigs (`metadata/+`) does
// not grant -- hence a policy of its own rather than reusing that one.
// Still read-only, still one path segment deep.
resource "vault_policy" "read_kubeconfigs_eso" {
  name   = "read-kubeconfigs-eso"
  policy = <<-EOT
    path "kubeconfigs/metadata/" {
      capabilities = ["list"]
    }
    path "kubeconfigs/metadata/+" {
      capabilities = ["read", "list"]
    }
    path "kubeconfigs/data/+" {
      capabilities = ["read"]
    }
  EOT
}

// Bound to the ESO chart's own ServiceAccount (release name `external-secrets`
// in namespace external-secrets) -- the ESO_STORE_AUTH_SA_* defaults of the
// flux store component.
resource "vault_kubernetes_auth_backend_role" "eso" {
  backend                          = vault_auth_backend.eso.path
  role_name                        = "eso"
  bound_service_account_names      = ["external-secrets"]
  bound_service_account_namespaces = ["external-secrets"]
  token_policies                   = [vault_policy.read_kubeconfigs_eso.name]
  token_ttl                        = 3600
}

variable "openbao_addr" {
  type        = string
  description = "OpenBao server address -- the instance on this cluster"
  default     = "https://openbao.platform.sthings.lab"
}

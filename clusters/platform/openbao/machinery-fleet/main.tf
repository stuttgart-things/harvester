// What a Crossplane management cluster needs on the OpenBao that runs on
// `platform`, to build clusters with ClusterStack: the KV mounts the built
// clusters' secrets and kubeconfigs live in, the policies over them, and the
// AppRoles machinery-hv logs in with. The consumer side -- provider configs,
// the policy mapping, the credential Secrets -- is
// clusters/machinery-hv-fleet-state.
//
// A ROOT OF ITS OWN, not more resources in ../approle.tf. That root's state
// carries the PKI, platform's own auth mount and the `crossplane` AppRole every
// VaultK8sAuth on crossplane-mgmt depends on; a plan here should never be able
// to touch any of that. The one link is deliberate and read-only: a second
// secret_id for the existing `crossplane` role (below).
//
// NAMES FOLLOW THE LabUL FLEET (stuttgart-things
// clusters/labda/vsphere/machinery-fleet-state/environmentconfigs.yaml, the
// cluster-vault-labul mapping), so a ClusterStack written there reads the same
// here and cluster-vault-sthings-lab.yaml is a copy, not a translation.
//
// ORDER: this before the fleet state lists vault-provider-configs.yaml and
// cluster-vault-sthings-lab.yaml. A role bound to a policy that does not exist
// logs in and is granted nothing; a mapping naming a missing policy fails the
// same silent way.

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
  skip_tls_verify = true
  // The token comes from VAULT_TOKEN. Without this the provider mints a child
  // token per run, which clutters the audit log and buys nothing here.
  skip_child_token = true
}

// ---- KV mounts --------------------------------------------------------------
//
// kubeconfigs      <cluster>             written by the join play / Workspace,
//                                        read back by provider-kubeconfig
// homerun2 …       <cluster><suffix>     per-cluster app secrets (VaultSecretSet)
//                  _<name>               shared, seeded by a human
// observability    <cluster>             the Platform's clusterSecrets entry
locals {
  app_mounts = toset(["homerun2", "schmetterpause", "observability"])
}

resource "vault_mount" "kubeconfigs" {
  path        = "kubeconfigs"
  type        = "kv"
  options     = { version = "2" }
  description = "Kubeconfigs of clusters built by machinery-hv, one entry per cluster"
}

resource "vault_mount" "app" {
  for_each    = local.app_mounts
  path        = each.key
  type        = "kv"
  options     = { version = "2" }
  description = "${each.key} secrets of clusters built by machinery-hv; `_` entries are shared and seeded by hand"
}

// ---- policies ---------------------------------------------------------------
//
// ONE PATH SEGMENT (`+`), on purpose: <mount>/data/<entry>, never deeper. A
// cluster's own entries and the shared `_` ones are all one level down
// (stuttgart-things#2999, #3017).
//
// read-*-clusters is what a BUILT cluster's ESO is bound to, through the
// cluster-vault-sthings-lab mapping. It reads every entry on the mount, as on
// LabUL -- per-cluster scoping is the mapping's job, not this policy's.
resource "vault_policy" "read_clusters" {
  for_each = local.app_mounts
  name     = "read-${each.key}-clusters"
  policy   = <<-EOT
    path "${each.key}/data/+" {
      capabilities = ["read"]
    }
    path "${each.key}/metadata/+" {
      capabilities = ["read", "list"]
    }
  EOT
}

// write-*-clusters is the WRITER's: machinery-hv composes a VaultSecretSet per
// app through it. It may write any cluster's entry and must never touch a
// shared `_` one -- those are seeded by hand and read by every cluster, so a
// write there would change every cluster's credential at once.
resource "vault_policy" "write_clusters" {
  for_each = local.app_mounts
  name     = "write-${each.key}-clusters"
  policy   = <<-EOT
    path "${each.key}/data/+" {
      capabilities = ["create", "read", "update", "delete"]
    }
    path "${each.key}/metadata/+" {
      capabilities = ["read", "list", "delete"]
    }
    path "${each.key}/data/_*" {
      capabilities = ["read"]
    }
    path "${each.key}/metadata/_*" {
      capabilities = ["read", "list"]
    }
  EOT
}

resource "vault_policy" "write_kubeconfigs" {
  name   = "write-kubeconfigs"
  policy = <<-EOT
    path "kubeconfigs/data/+" {
      capabilities = ["create", "read", "update", "delete"]
    }
    path "kubeconfigs/metadata/+" {
      capabilities = ["read", "list", "delete"]
    }
  EOT
}

resource "vault_policy" "read_kubeconfigs" {
  name   = "read-kubeconfigs"
  policy = <<-EOT
    path "kubeconfigs/data/+" {
      capabilities = ["read"]
    }
    path "kubeconfigs/metadata/+" {
      capabilities = ["read", "list"]
    }
  EOT
}

// ---- AppRoles ---------------------------------------------------------------
//
// secret_id_ttl 0 and token_period 0 for the reason ../openbao.tf gives: an
// expiring credential nobody watches is how certificates silently stopped
// being issued before. Rotation is explicit -- taint the secret_id resource,
// apply, re-encrypt the fleet-state Secrets.
locals {
  approles = {
    "machinery-hv-cluster-secrets-writer" = [for p in vault_policy.write_clusters : p.name]
    "machinery-hv-kubeconfig-writer"      = [vault_policy.write_kubeconfigs.name]
    "machinery-hv-kubeconfig-reader"      = [vault_policy.read_kubeconfigs.name]
  }
}

resource "vault_approle_auth_backend_role" "fleet" {
  for_each       = local.approles
  backend        = "approle"
  role_name      = each.key
  token_policies = each.value
  token_ttl      = 3600
  token_max_ttl  = 0
  secret_id_ttl  = 0
}

resource "vault_approle_auth_backend_role_secret_id" "fleet" {
  for_each  = vault_approle_auth_backend_role.fleet
  backend   = "approle"
  role_name = each.value.role_name
  metadata  = jsonencode({ cluster = "machinery-hv" })
}

// The k8s-auth bootstrap: the credential machinery-hv mounts the Kubernetes
// auth backends of the clusters it builds with (provider-vault
// ClusterProviderConfig `vault`). That is exactly what the existing
// `crossplane` role and its crossplane-auth-admin policy exist for
// (../approle.tf), so this is a SECOND secret_id on that role rather than a
// second role: crossplane-mgmt keeps its own, and either can be revoked
// without touching the other.
resource "vault_approle_auth_backend_role_secret_id" "k8sauth_bootstrap" {
  backend   = "approle"
  role_name = "crossplane"
  metadata  = jsonencode({ cluster = "machinery-hv" })
}

data "vault_approle_auth_backend_role_id" "crossplane" {
  backend   = "approle"
  role_name = "crossplane"
}

variable "openbao_addr" {
  type        = string
  description = "OpenBao server address -- the instance on the platform cluster"
  default     = "https://openbao.platform.sthings.lab"
}

// ---- outputs ------------------------------------------------------------------
//
// Read ONLY by ./render-fleet-secrets.sh, which encrypts them straight into
// clusters/machinery-hv-fleet-state/secrets/ -- never into a plaintext file.
output "approles" {
  description = "role_id and secret_id per AppRole machinery-hv logs in with"
  sensitive   = true
  value = merge(
    {
      for k, r in vault_approle_auth_backend_role.fleet : k => {
        role_id   = r.role_id
        secret_id = vault_approle_auth_backend_role_secret_id.fleet[k].secret_id
      }
    },
    {
      "crossplane" = {
        role_id   = data.vault_approle_auth_backend_role_id.crossplane.role_id
        secret_id = vault_approle_auth_backend_role_secret_id.k8sauth_bootstrap.secret_id
      }
    }
  )
}

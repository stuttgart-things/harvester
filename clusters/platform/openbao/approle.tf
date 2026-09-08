// AppRole for Crossplane — the credential that lets `VaultK8sAuth` XRs create
// Kubernetes auth mounts, so that a new cluster no longer needs a human to run
// terraform in clusters/<name>/openbao before its ClusterIssuer works.
//
// WHY APPROLE AND NOT A TOKEN. The bootstrap/vault-auth Configuration's field
// is called `vaultTokenSecret`, which is misleading: the composed module does
// `auth_login` with role_id + secret_id and declares no `vault_token` variable
// at all. A token there satisfies nothing — tofu fails the plan with "No value
// for required variable".
//
// WHAT THIS COSTS, stated plainly. The policy below carries `sudo` on
// `sys/auth/*`, because enabling an auth backend is a root-protected operation.
// That means whoever holds this secret_id can mount AND UNMOUNT any auth
// backend on this instance — including the ones cert-manager authenticates
// through. Today that power sits in a root token a human uses occasionally;
// after this it also sits, permanently and online, in a Secret on
// crossplane-mgmt. That is a real trade and not obviously the right one for
// every estate; it is taken here because the alternative is a manual terraform
// run standing between every new cluster and a working certificate.
//
// A WILDCARD POLICY IS NOT A SUBSTITUTE. `path "*" { capabilities = [...] }`
// authenticates fine and then 403s on the mount, because a wildcard does not
// imply sudo. It reads like a broken package rather than a missing capability.
// Documented the hard way in crossplane-configurations
// bootstrap/vault-auth/README.md.
resource "vault_policy" "crossplane_auth_admin" {
  name   = "crossplane-auth-admin"
  policy = <<-EOT
# Mounting an auth backend is root-protected: sudo is required, and a wildcard
# policy without it authenticates and then 403s.
path "sys/auth/*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}

# Without delete above, `tofu destroy` 403s, the Workspace hangs in its
# finalizer and the mount is orphaned. Verified on kind3, 2026-08-13 (see the
# Configuration's README) -- so teardown is part of the grant, not an oversight.
path "sys/auth" {
  capabilities = ["read", "list"]
}

# The mount's own configuration and roles. `+` is one path segment, i.e.
# auth/test1-sthings-certmanager/... and nothing deeper or wider.
path "auth/+/config" {
  capabilities = ["create", "read", "update", "delete"]
}

path "auth/+/role/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

# The XR's `policies` field creates policies named {clusterName}-{name} and
# appends them to tokenPolicies. Without this it can only reference policies
# that already exist -- and a role bound to a policy that does not exist logs in
# successfully and is granted nothing, which surfaces as a denied signing
# request much later rather than as an error.
path "sys/policies/acl/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

# Read-only, for plan-time lookups.
path "sys/mounts" {
  capabilities = ["read", "list"]
}
  EOT
}

// The role_id is not secret; the secret_id is, and it lands in TERRAFORM STATE
// (tfstate-default-openbao-platform-sthings, a Secret in cert-manager on this
// cluster). That is the same objection raised against letting Terraform hold
// the PKI root key in ./pki.tf -- but not the same weight: a secret_id is
// scoped by the policy above and can be rotated by tainting the resource,
// whereas the CA key could not be regenerated without invalidating the estate.
//
// To rotate:  terraform taint 'module.openbao-base-setup.vault_approle_auth_backend_role_secret_id.approle_secret["crossplane"]'
output "crossplane_approle_role_id" {
  description = "role_id for the crossplane AppRole. Not secret."
  value       = try(module.openbao-base-setup.role_id[0], null)
}

output "crossplane_approle_secret_id" {
  description = "secret_id for the crossplane AppRole. Feed into the Secret the VaultK8sAuth XR reads."
  value       = try(module.openbao-base-setup.secret_id["crossplane"], null)
  sensitive   = true
}

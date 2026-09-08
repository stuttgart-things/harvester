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
// THE POLICY WAS NARROWED AFTER THE FIRST APPLY. As first written it also
// carried sys/policies/acl/*, and `auth/+/role/*` matched auth/approle/role/
// crossplane -- its own role. That combination was a complete escalation to
// root-equivalent. Verified against the live instance, then closed; the deny
// block in the policy has the detail. Anything added here should be re-checked
// with sys/capabilities-self rather than reasoned about.
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

# The mount's own configuration and roles. `+` is one path segment.
path "auth/+/config" {
  capabilities = ["create", "read", "update", "delete"]
}

path "auth/+/role/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

# Read-only, for plan-time lookups.
path "sys/mounts" {
  capabilities = ["read", "list"]
}

# NOTE: sys/policies/acl/* is deliberately ABSENT. The VaultK8sAuth XR has a
# `policies` field that CREATES policies named {clusterName}-{name}; without
# this path that field cannot be used, and `tokenPolicies` may only REFERENCE
# policies that already exist. That costs nothing here -- every cluster binds to
# `pki-issue`, created by ./pki.tf -- and it removes the ingredient that made
# the escalation below possible: the ability to write a policy granting
# anything. Adding it back means re-reading the deny block.

# ---- THE DENIES ARE THE POINT --------------------------------------------
# `+` above matches ANY single segment, and "approle" is a single segment. So
# `auth/+/role/*` matched `auth/approle/role/crossplane` -- this credential's
# OWN role. Combined with the ability to create policies, that was a complete
# escalation to root-equivalent, verified against the live instance on
# 2026-09-08 with sys/capabilities-self:
#
#   auth/approle/role/crossplane            [create delete list read update]
#   auth/approle/role/crossplane/secret-id  [create delete list read update]
#
#   1. create a policy granting everything
#   2. rewrite own token_policies to include it
#   3. log in again
#
# An explicit deny on a more specific path always wins in a Vault ACL, so these
# close it without narrowing the paths above.
path "auth/approle/*" {
  capabilities = ["deny"]
}

path "sys/auth/approle" {
  capabilities = ["deny"]
}

# It must not be able to rewrite the policy it runs under.
path "sys/policies/acl/crossplane-auth-admin" {
  capabilities = ["deny"]
}

# pki-issue is what every cert-manager auth role binds to. Overwriting or
# deleting it does not fail loudly: the login still succeeds and is granted
# nothing, so it surfaces as certificates that quietly stop being issued.
path "sys/policies/acl/pki-issue" {
  capabilities = ["deny"]
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

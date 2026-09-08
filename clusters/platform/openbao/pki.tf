// PKI — everything EXCEPT the root CA.
//
// WHY THIS IS NOT var.pki_enabled ANY MORE.
//
// The module gates five resources behind one flag: the mount, the signing role,
// the policy, the URL config — and `vault_pki_secret_backend_root_cert`, which
// GENERATES a root. There is no way to keep the first four and skip the last.
//
// This cluster's root CA is not Terraform's to generate. On 2026-09-07 the root
// token was lost (see README, step 2), OpenBao had to be re-initialised, and the
// CA private key was rescued out of raft storage via recovery mode and imported
// by hand with `bao write pki/config/ca`. That key must never pass through
// Terraform: `terraform apply` writes it into the state, and the state is a
// plain Secret in cert-manager.
//
// With the module's PKI left on, `terraform plan` proposed creating a *second*
// root on every run. Applying that would have replaced the rescued CA silently
// and invalidated every certificate, agent enrolment and trust store in the
// estate — the exact outcome the rescue existed to avoid.
//
// So: pki_enabled = false in openbao.tf, the four harmless resources declared
// here, and the CA stays a hand-managed artefact. That is the same split the
// runbook already makes for `bao operator init`, and for the same reason.
//
// THE CA IS THEREFORE NOT IN CODE. Rotating or replacing it is a documented
// manual procedure, not an apply. See ./README.md.

resource "vault_mount" "pki" {
  path                      = "pki"
  type                      = "pki"
  description               = "PKI secrets engine for sthings.lab"
  default_lease_ttl_seconds = 3600
  max_lease_ttl_seconds     = 315360000
}

resource "vault_pki_secret_backend_config_urls" "urls" {
  backend                 = vault_mount.pki.path
  issuing_certificates    = ["${var.openbao_addr}/v1/pki/ca"]
  crl_distribution_points = ["${var.openbao_addr}/v1/pki/crl"]
}

// One year. The certificates themselves are issued for 90 days by cert-manager
// (duration: 2160h in the Certificate manifests) and renewed 15 days before
// expiry — this only has to be the ceiling, not the value.
//
// max_ttl IS IN SECONDS, not "8760h". The API returns seconds, so a duration
// string here never matches what comes back and every plan shows
// `"31536000" -> "8760h"` forever. Same year, permanent diff.
//
// key_bits IS 2048 AND MUST STAY 2048. This is a SIGNING role: cert-manager
// generates the key and submits a CSR, and Vault validates that CSR against
// key_type/key_bits. cert-manager's default is RSA 2048 and none of our
// Certificate manifests set spec.privateKey, so every CSR in the estate is
// 2048-bit.
//
// This file said 4096 from the day it was written (harvester#178) while the
// live role has always been 2048. Nothing broke only because nobody applied
// this directory afterwards. The first apply for any unrelated reason would
// have raised the role to 4096 and then REJECTED EVERY SIGNING REQUEST in the
// fleet — clusters keep running, certificates simply stop renewing, and the
// issuer goes on reporting Ready because it verifies the login and not the
// signing. Found on 2026-09-08 in the plan for the Crossplane AppRole, which
// had no business touching this resource at all.
//
// Raising it to 4096 is possible, but it is a fleet-wide change: every
// Certificate would need spec.privateKey.size: 4096, and they would have to
// land BEFORE the role changes, not after.
resource "vault_pki_secret_backend_role" "sthings_lab" {
  backend            = vault_mount.pki.path
  name               = "sthings-lab"
  max_ttl            = 31536000 // 8760h, one year — seconds, see above
  allowed_domains    = ["sthings.lab"]
  allow_subdomains   = true
  allow_bare_domains = false
  key_type           = "rsa"
  key_bits           = 2048
  generate_lease     = true
}

// The policy the Kubernetes auth role binds to. Deliberately PKI-only: it can
// sign and read, and nothing else. Verified on 2026-09-07 that it offers no
// escalation path — which was bad news that day (no way back into an OpenBao
// whose root token was gone) and is the correct scoping every other day.
resource "vault_policy" "pki_issue" {
  name   = "pki-issue"
  policy = <<-EOT
path "pki/issue/*" {
  capabilities = ["create", "update"]
}

path "pki/sign/*" {
  capabilities = ["create", "update"]
}

path "pki/certs" {
  capabilities = ["list"]
}

path "pki/cert/*" {
  capabilities = ["read"]
}

path "pki/ca" {
  capabilities = ["read"]
}

path "pki/ca_chain" {
  capabilities = ["read"]
}

path "pki/crl" {
  capabilities = ["read"]
}

path "pki/roles/*" {
  capabilities = ["read"]
}
  EOT
}

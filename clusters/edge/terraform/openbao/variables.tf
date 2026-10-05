variable "openbao_addr" {
  type        = string
  description = "OpenBao through the Gateway (TLS from the edge CA); per environment, env/*.auto.tfvars.json"
}

// The password of the userpass user `terraform` (policy: PKI at pki/ only),
// from secrets/edge/app-values.enc.yaml OPENBAO_TERRAFORM_PASSWORD (SOPS) --
// passed as terraform.tfvars.json, never in a *.tf file (README.md).
variable "openbao_password" {
  type      = string
  sensitive = true
}

// The names devices may get certificates for via ACME. Subdomains of these
// are allowed, the bare names are not. Per environment (env/*.auto.tfvars.json):
// the lab domain on the test VM, edge.sthings.lab on the box (OpenWrt names
// the devices there).
variable "acme_allowed_domains" {
  type = list(string)
}

// not-required: any client that passes the challenge gets a certificate.
// new-account-required / always-required: an EAB token from
// `bao write -f pki/acme/new-eab` is needed to register.
variable "acme_eab_policy" {
  type    = string
  default = "not-required"
}

// The DNS server OpenBao uses to resolve device names for the ACME
// challenges. Empty = the pod's resolver (cluster DNS). Set it to the edge
// network's DNS once devices are named there: on the box the OpenWrt router
// (env/box.auto.tfvars.json), which knows the devices' static leases.
variable "acme_dns_resolver" {
  type    = string
  default = ""
}

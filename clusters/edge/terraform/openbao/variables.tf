variable "openbao_addr" {
  type        = string
  description = "OpenBao through the Gateway (TLS from the edge CA)"
  default     = "https://openbao.edge-tt-test1.4sthings.tiab.ssc.sva.de"
}

// The root token from `bao operator init`, from
// secrets/edge/openbao-init.enc.yaml (SOPS) -- passed as
// terraform.tfvars.json, never in a *.tf file (README.md).
variable "openbao_token" {
  type      = string
  sensitive = true
}

// The names devices may get certificates for via ACME. Subdomains of these
// are allowed, the bare names are not.
variable "acme_allowed_domains" {
  type    = list(string)
  default = ["edge-tt-test1.4sthings.tiab.ssc.sva.de"]
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
// network's DNS once devices are named there.
variable "acme_dns_resolver" {
  type    = string
  default = ""
}

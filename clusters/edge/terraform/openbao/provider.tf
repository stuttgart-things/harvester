provider "vault" {
  address = var.openbao_addr
  token   = var.openbao_token
  // The edge root CA: clusters/edge/edge-root-ca.crt, put next to this code
  // by dagger/terraform --extra-files (README.md). Public, valid until 2046.
  ca_cert_file = "${path.module}/edge-root-ca.crt"
  // OpenBao has no Vault Enterprise namespaces; a child token adds nothing.
  skip_child_token = true
}

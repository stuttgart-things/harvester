provider "vault" {
  address = var.openbao_addr
  token   = var.openbao_token
  // The edge root CA, a copy of ../../edge-root-ca.crt (dagger/terraform mounts
  // only this directory). Public, valid until 2046.
  ca_cert_file = "${path.module}/edge-root-ca.crt"
  // OpenBao has no Vault Enterprise namespaces; a child token adds nothing.
  skip_child_token = true
}

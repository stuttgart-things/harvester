provider "vault" {
  address = var.openbao_addr
  // Login as the PKI-only user `terraform` (OpenBao self-init, flux
  // components/self-init-userpass) -- no root token exists on a self-initialised
  // instance. Its password: secrets/edge/app-values OPENBAO_TERRAFORM_PASSWORD.
  auth_login_userpass {
    username = "terraform"
    password = var.openbao_password
  }
  // The edge root CA: clusters/edge/edge-root-ca.crt, put next to this code
  // by dagger/terraform --extra-files (README.md). Public, valid until 2046.
  ca_cert_file = "${path.module}/edge-root-ca.crt"
  // OpenBao has no Vault Enterprise namespaces; a child token adds nothing.
  skip_child_token = true
}

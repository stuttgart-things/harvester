terraform {
  backend "kubernetes" {
    secret_suffix = "vault-infra-sthings" # pragma: allowlist secret
    namespace     = "vault"
    config_path   = "/home/sthings/.kube/infra.sthings.lab"
  }
}

terraform {
  backend "kubernetes" {
    secret_suffix = "vault-infra-sthings"
    namespace     = "vault"
    config_path   = "/home/sthings/.kube/infra.sthings.lab"
  }
}

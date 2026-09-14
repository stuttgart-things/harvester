terraform {
  backend "kubernetes" {
    secret_suffix = "openbao-tabletennis-sthings" # pragma: allowlist secret
    namespace     = "cert-manager"
    config_path   = "/home/sthings/.kube/tabletennis"
  }
}

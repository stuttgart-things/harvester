terraform {
  backend "kubernetes" {
    secret_suffix = "openbao-ferdinand-sthings" # pragma: allowlist secret
    namespace     = "cert-manager"
    config_path   = "/home/sthings/.kube/ferdinand"
  }
}

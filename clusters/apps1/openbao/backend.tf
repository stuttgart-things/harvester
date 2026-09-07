terraform {
  backend "kubernetes" {
    secret_suffix = "openbao-apps1-sthings" # pragma: allowlist secret
    namespace     = "cert-manager"
    config_path   = "/home/sthings/.kube/apps1"
  }
}

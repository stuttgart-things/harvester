terraform {
  backend "kubernetes" {
    secret_suffix = "openbao-k3s-xp-sthings" # pragma: allowlist secret
    namespace     = "cert-manager"
    config_path   = "/home/sthings/.kube/k3s-xp"
  }
}

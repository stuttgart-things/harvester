terraform {
  backend "kubernetes" {
    secret_suffix = "vault-platform-sthings" # pragma: allowlist secret
    namespace     = "cert-manager"
    config_path   = "/home/sthings/.kube/platform"
  }
}

terraform {
  backend "kubernetes" {
    secret_suffix = "vault-xplane-sthings" # pragma: allowlist secret
    namespace     = "cert-manager"
    config_path   = "/home/sthings/.kube/xplane"
  }
}

terraform {
  backend "kubernetes" {
    secret_suffix = "openbao-xplane-sthings" # pragma: allowlist secret
    namespace     = "cert-manager"
    config_path   = "/home/sthings/.kube/xplane"
  }
}

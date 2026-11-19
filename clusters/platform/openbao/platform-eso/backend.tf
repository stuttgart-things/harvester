terraform {
  backend "kubernetes" {
    secret_suffix = "openbao-platform-eso" # pragma: allowlist secret
    namespace     = "cert-manager"
    config_path   = "/home/sthings/.kube/platform.sthings.lab"
  }
}

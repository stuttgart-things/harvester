terraform {
  backend "kubernetes" {
    secret_suffix = "openbao-app-secrets" # pragma: allowlist secret
    namespace     = "cert-manager"
    config_path   = "/home/sthings/.kube/platform.sthings.lab"
  }
}

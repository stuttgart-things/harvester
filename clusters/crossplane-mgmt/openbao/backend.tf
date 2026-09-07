terraform {
  backend "kubernetes" {
    secret_suffix = "openbao-crossplane-mgmt-sthings" # pragma: allowlist secret
    namespace     = "cert-manager"
    config_path   = "/home/sthings/.kube/crossplane-mgmt"
  }
}

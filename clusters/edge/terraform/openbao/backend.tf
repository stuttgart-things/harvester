// State on the edge node itself, Secret openbao/tfstate-default-openbao-edge.
// config_path is where dagger/terraform mounts --kube-config; for a local run
// pass -backend-config=config_path=$HOME/.kube/edge-tt-test1.
//
// Only configuration lives here (mount, URLs, role, ACME). No private key:
// the intermediate is generated INSIDE OpenBao (./sign-intermediate.sh) and
// the root key never comes near Terraform.
terraform {
  backend "kubernetes" {
    secret_suffix = "openbao-edge" # pragma: allowlist secret
    namespace     = "openbao"
    config_path   = "/root/.kube/config"
  }
}

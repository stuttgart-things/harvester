// State lives in a Secret on the cluster this configures, like every sibling
// openbao root here. `cert-manager` as the namespace is the convention those
// follow, not a requirement of the state itself.
//
// config_path is THIS cluster's kubeconfig, and it is a DHCP lease
// (192.168.10.117 at the time of writing). Rebuild the VM onto a new address
// and both this backend and var.kubeconfig_path point at nothing until the
// kubeconfig is refetched -- see clusters/homerun2-dev/README.md, step 3.
terraform {
  backend "kubernetes" {
    secret_suffix = "openbao-homerun2-dev" # pragma: allowlist secret
    namespace     = "cert-manager"
    config_path   = "/home/sthings/.kube/homerun2-dev"
  }
}

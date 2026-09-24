// State lives in a Secret on the cluster this configures, like every sibling
// openbao root here. `cert-manager` as the namespace is the convention those
// follow, not a requirement of the state itself.
//
// config_path is THIS cluster's kubeconfig, and its server address is a DHCP
// lease until the router has a static one for the VM's MAC. Rebuild the VM
// onto a new address and both this backend and var.kubeconfig_path point at
// nothing until the kubeconfig is refetched -- see clusters/machinery-hv/README.md, step 3.
terraform {
  backend "kubernetes" {
    secret_suffix = "openbao-machinery-hv" # pragma: allowlist secret
    namespace     = "cert-manager"
    config_path   = "/home/sthings/.kube/machinery-hv"
  }
}

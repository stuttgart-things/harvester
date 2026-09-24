// State in a Secret on `platform`, beside the OpenBao it configures -- the
// same place ../backend.tf keeps its own, under a suffix of its own. It holds
// the AppRole secret_ids in plain text, which is why it is on the cluster that
// already holds the OpenBao they unlock and not in git.
terraform {
  backend "kubernetes" {
    secret_suffix = "openbao-machinery-fleet" # pragma: allowlist secret
    namespace     = "cert-manager"
    config_path   = "/home/sthings/.kube/platform.sthings.lab"
  }
}

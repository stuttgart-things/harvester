# State on platform, in the namespace of the ZITADEL it describes
# (apps-platform → zitadel). It holds the portal client secrets and any
# initial user passwords in cleartext, so it sits next to the instance and
# nowhere else.
terraform {
  required_version = ">= 1.5"
  backend "kubernetes" {
    secret_suffix = "zitadel-config" # pragma: allowlist secret
    namespace     = "zitadel"
    config_path   = "/home/sthings/.kube/platform.sthings.lab"
  }
  required_providers {
    zitadel = {
      source  = "zitadel/zitadel"
      version = "~> 3.0"
    }
  }
}

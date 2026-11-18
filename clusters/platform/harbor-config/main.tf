# Projects and registry endpoints of the platform Harbor (goharbor chart,
# ../apps/goharbor.yaml, harvester#693). Before #693 they were clicked in the
# UI of the Bitnami Harbor; now they are here.
#
# State on platform, in the namespace of the Harbor it describes. Apply:
# README.md.

terraform {
  required_version = ">= 1.5"
  backend "kubernetes" {
    secret_suffix = "harbor-config" # pragma: allowlist secret
    namespace     = "goharbor"
    config_path   = "/home/sthings/.kube/platform.sthings.lab"
  }
  required_providers {
    harbor = {
      source  = "goharbor/harbor"
      version = "~> 3.12"
    }
  }
}

variable "harbor_url" {
  description = "Harbor base URL (the lab CA comes in through SSL_CERT_FILE)."
  type        = string
  default     = "https://harbor.platform.sthings.lab"
}

variable "harbor_password" {
  description = "Password of the local admin (Secret goharbor-secrets)."
  type        = string
  sensitive   = true
}

provider "harbor" {
  url      = var.harbor_url
  username = "admin"
  password = var.harbor_password
}

# Pull-through cache for Docker Hub: docker.harbor.platform.sthings.lab/<repo>
# through harbor-project-proxy, or harbor.platform.sthings.lab/docker/<repo>.
# Anonymous on both sides (public project, no Docker Hub credentials).
resource "harbor_registry" "dockerhub" {
  provider_name = "docker-hub"
  name          = "docker"
  endpoint_url  = "https://hub.docker.com"
}

resource "harbor_project" "docker" {
  name        = "docker"
  public      = true
  registry_id = harbor_registry.dockerhub.registry_id
}

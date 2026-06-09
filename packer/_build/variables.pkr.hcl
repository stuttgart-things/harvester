# Shared variable declarations for all packer images (golden + dev).
# Per-image values are supplied via the image's build.pkrvars.hcl, e.g.
#   packer/golden/sthings-u26/build.pkrvars.hcl
#   packer/dev/u26-dev/build.pkrvars.hcl
# Build runs from packer/_build/, so file paths in var-files are relative to
# this directory (e.g. ../golden/sthings-u26/users.yaml).

variable "source_url" {
  type        = string
  description = "Base image to build from: upstream cloud image for golden, the published golden artifact for dev"
}

variable "source_checksum" {
  type        = string
  default     = "none"
  description = "Checksum of source_url, e.g. 'file:https://.../SHA256SUMS' or 'none'"
}

variable "image_name" {
  type        = string
  description = "Name of the produced image / Harvester VMI (e.g. sthings-u26, u26-dev)"
}

variable "namespace" {
  type    = string
  default = "default"
}

variable "output_location" {
  type    = string
  default = "output/"
}

variable "packages_file" {
  type        = string
  description = "Path to this image's packages.yaml (relative to packer/_build/)"
}

variable "users_file" {
  type        = string
  description = "Path to this image's users.yaml (relative to packer/_build/)"
}

variable "harvester_vip" {
  type        = string
  default     = ""
  description = "Harvester VIP address (passed via GH workflow)"
}

variable "harvester_password" {
  type        = string
  default     = ""
  sensitive   = true
  description = "Harvester admin password (passed via GH workflow)"
}

variable "upload_to_harvester" {
  type        = string
  default     = "false"
  description = "Set to 'true' to upload the image to Harvester after build"
}

# --- OS-specific knobs (defaults target the Ubuntu cloud image) -------------
# Other images (e.g. Rocky) override these in their build.pkrvars.hcl.

variable "ssh_username" {
  type        = string
  default     = "ubuntu"
  description = "Default cloud-image user packer logs in as (e.g. 'ubuntu', 'rocky')"
}

variable "ssh_timeout" {
  type        = string
  default     = "5m"
  description = "How long packer waits for SSH to come up"
}

variable "qemuargs" {
  type        = list(list(string))
  default     = [["-cdrom", "cidata.iso"]]
  description = "Extra QEMU args. Override to add machine/cpu flags some images need."
}

variable "disk_size" {
  type        = string
  default     = "10G"
  description = "Image disk size. Bump for node images that bake airgap artifacts (k3s/rke2)."
}

# --- Airgap artifact baking (opt-in; empty = skip) --------------------------
# When set, the build stages the engine's airgap artifacts (binary + images)
# into the image at BUILD time, so edge nodes boot with zero network dependency
# for the cluster core. Set these in a node image's build.pkrvars.hcl.

variable "k3s_version" {
  type        = string
  default     = ""
  description = "k3s release to stage (e.g. v1.31.5+k3s1). Empty = do not bake k3s."
}

variable "k3s_artifacts_base_url" {
  type        = string
  default     = "https://artifacts.platform.sthings.lab/k3s"
  description = "Base URL of the k3s airgap artifacts in S3; expects <base>/<version>/{k3s,k3s-airgap-images-amd64.tar.zst,sha256sum-amd64.txt}"
}

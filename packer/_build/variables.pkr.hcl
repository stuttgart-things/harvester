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

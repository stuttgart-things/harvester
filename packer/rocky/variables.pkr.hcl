variable "rocky_url" {
  type    = string
  default = "https://dl.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-GenericCloud.latest.x86_64.qcow2"
}

variable "rocky_checksum" {
  type    = string
  default = "15d81d3434b298142b2fdd8fb54aef2662684db5c082cc191c3c79762ed6360c" # pragma: allowlist secret
}

variable "image_name" {
  type    = string
  default = "rocky-9-base"
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
  type    = string
  default = "packages.yaml"
}

variable "users_file" {
  type    = string
  default = "users.yaml"
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

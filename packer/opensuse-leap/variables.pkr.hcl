variable "opensuse_url" {
  type    = string
  default = "https://download.opensuse.org/repositories/Cloud:/Images:/Leap_15.6/images/openSUSE-Leap-15.6.x86_64-NoCloud.qcow2"
}

variable "opensuse_checksum" {
  type    = string
  default = "08ffa155237137770109fcf5174a560268cf6803091a9b2cdd3199799263fe1e"
}

variable "image_name" {
  type    = string
  default = "opensuse-leap-base"
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

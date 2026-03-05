variable "ubuntu_url" {
  type    = string
  default = "https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"
}

variable "ubuntu_checksum" {
  type    = string
  default = "file:https://cloud-images.ubuntu.com/jammy/current/SHA256SUMS"
}

variable "image_name" {
  type    = string
  default = "ubuntu-jammy-base"
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

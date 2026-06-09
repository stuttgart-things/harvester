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

# --- Airgap image baking (opt-in; empty list = skip) ------------------------
# When airgap_image_tars is non-empty, the build downloads those image tarballs
# from S3 at BUILD time and stages them into the engine's agent images dir, so
# edge nodes boot with zero network dependency for the cluster core (containerd
# imports every tarball in that dir on start). Set these in a node image's
# build.pkrvars.hcl.

variable "airgap_images_base_url" {
  type        = string
  default     = "https://artifacts.platform.sthings.lab/images"
  description = "Base URL of the flat S3 'images' bucket holding the airgap image tarballs."
}

variable "airgap_image_tars" {
  type        = list(string)
  default     = []
  description = "Image tarballs to stage from airgap_images_base_url (e.g. k3s-airgap-images-amd64.tar.zst, cilium-images.tar). Empty = skip."
}

variable "airgap_images_dir" {
  type        = string
  default     = "/var/lib/rancher/k3s/agent/images"
  description = "Where to stage the tarballs (k3s: /var/lib/rancher/k3s/agent/images, rke2: /var/lib/rancher/rke2/agent/images)."
}

# --- SSH password for the curated user (besides its keys) -------------------
# Applies to every image. The hash is computed in CI from the STHINGS_PASSWORD
# secret (openssl passwd -6); empty = key-only (password stays locked).

variable "sthings_password" {
  type        = string
  default     = ""
  sensitive   = true
  description = "SHA-512 crypt hash for password_user's password (computed in CI from the STHINGS_PASSWORD secret). Empty = key-only."
}

variable "password_user" {
  type        = string
  default     = "sthings"
  description = "Which user gets sthings_password applied in addition to its SSH keys."
}

# --- Private CA trust (installed into every image) --------------------------

variable "ca_cert_url" {
  type        = string
  default     = "https://vault.infra.sthings.lab/v1/pki/ca/pem"
  description = "PEM CA endpoint to install into the image trust store (fetched with curl -sk at build). Empty = skip."
}

variable "ca_cert_name" {
  type        = string
  default     = "sthings-lab-ca.crt"
  description = "Filename for the installed CA in the system trust anchors dir."
}

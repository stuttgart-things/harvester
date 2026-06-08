# Golden base image: sthings-rocky9 (Rocky Linux 9 GenericCloud)
# Curated, review-gated. Built fresh from the upstream Rocky cloud image.
# Build runs from packer/_build/ -> paths below are relative to that dir.

source_url      = "https://dl.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-GenericCloud.latest.x86_64.qcow2"
source_checksum = "none" # 'latest' URL is unpinned; pin a versioned image + checksum to enable verification

image_name    = "sthings-rocky9"
users_file    = "../golden/sthings-rocky9/users.yaml"
packages_file = "../golden/sthings-rocky9/packages.yaml"

# Rocky-specific overrides of the Ubuntu defaults (see packer/_build/variables.pkr.hcl).
# Rocky cloud images expose a 'rocky' login user and want an explicit q35 machine.
ssh_username = "rocky"
ssh_timeout  = "10m"
qemuargs = [
  ["-cdrom", "cidata.iso"],
  ["-machine", "type=q35,accel=kvm"],
  ["-cpu", "host"],
]

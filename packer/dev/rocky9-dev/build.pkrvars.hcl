# Dev playground image: rocky9-dev
# Self-service, auto-merged. Layered ON TOP of the golden sthings-rocky9 image so
# a build only installs the delta (devs' SSH keys + extra packages).
# Build runs from packer/_build/ -> paths below are relative to that dir.
#
# source_url is the golden sthings-rocky9 base published to the MinIO artifact store
# by the golden build (see packer/_build/publish-base.sh). The golden image must be
# built + published at least once before a dev build can run.
#
# source_checksum pins that base: publish-base.sh writes a .sha256 next to the
# image and packer verifies against it, so a dev build cannot silently layer on a
# truncated or half-published golden. The file holds a bare hash with no filename,
# which packer's file: prefix accepts (verified: a wrong hash fails the build).
source_url      = "https://artifacts.platform.sthings.lab/packer/golden/sthings-rocky9/sthings-rocky9-amd64.img"
source_checksum = "file:https://artifacts.platform.sthings.lab/packer/golden/sthings-rocky9/sthings-rocky9-amd64.img.sha256"

image_name    = "rocky9-dev"
users_file    = "../dev/rocky9-dev/users.yaml"
packages_file = "../dev/rocky9-dev/packages.yaml"

# Rocky-specific overrides (the golden base still logs in as the 'rocky' user).
ssh_username = "rocky"
ssh_timeout  = "10m"
qemuargs = [
  ["-cdrom", "cidata.iso"],
  ["-machine", "type=q35,accel=kvm"],
  ["-cpu", "host"],
]

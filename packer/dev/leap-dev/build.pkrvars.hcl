# Dev playground image: leap-dev
# Self-service, auto-merged. Layered ON TOP of the golden sthings-leap image so
# a build only installs the delta (devs' SSH keys + extra packages).
# Build runs from packer/_build/ -> paths below are relative to that dir.
#
# source_url is the golden sthings-leap base published to the MinIO artifact store
# by the golden build (see packer/_build/publish-base.sh). The golden image must be
# built + published at least once before a dev build can run.
#
# source_checksum pins that base: publish-base.sh writes a .sha256 next to the
# image and packer verifies against it, so a dev build cannot silently layer on a
# truncated or half-published golden. The file holds a bare hash with no filename,
# which packer's file: prefix accepts (verified: a wrong hash fails the build).
source_url      = "https://artifacts.platform.sthings.lab/packer/golden/sthings-leap/sthings-leap-amd64.img"
source_checksum = "file:https://artifacts.platform.sthings.lab/packer/golden/sthings-leap/sthings-leap-amd64.img.sha256"

image_name    = "leap-dev"
users_file    = "../dev/leap-dev/users.yaml"
packages_file = "../dev/leap-dev/packages.yaml"

# openSUSE-specific override (the golden base still logs in as the 'opensuse' user).
ssh_username = "opensuse"

# Dev playground image: leap-dev
# Self-service, auto-merged. Layered ON TOP of the golden sthings-leap image so
# a build only installs the delta (devs' SSH keys + extra packages).
# Build runs from packer/_build/ -> paths below are relative to that dir.
#
# source_url is the golden sthings-leap base published to the MinIO artifact store
# by the golden build (see packer/_build/publish-base.sh). The golden image must be
# built + published at least once before a dev build can run.
source_url      = "https://artifacts.platform.sthings.lab/packer/golden/sthings-leap/sthings-leap-amd64.img"
source_checksum = "none"

image_name    = "leap-dev"
users_file    = "../dev/leap-dev/users.yaml"
packages_file = "../dev/leap-dev/packages.yaml"

# openSUSE-specific override (the golden base still logs in as the 'opensuse' user).
ssh_username = "opensuse"

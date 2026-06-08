# Dev playground image: u26-dev
# Self-service, auto-merged. Layered ON TOP of the golden sthings-u26 image so
# a build only installs the delta (devs' SSH keys + extra packages).
# Build runs from packer/_build/ -> paths below are relative to that dir.
#
# source_url is the golden sthings-u26 base published to the MinIO artifact store
# by the golden build (see packer/_build/publish-base.sh). The golden image must be
# built + published at least once before a dev build can run.
source_url      = "https://artifacts.platform.sthings.lab/packer/golden/sthings-u26/sthings-u26-amd64.img"
source_checksum = "none"

image_name    = "u26-dev"
users_file    = "../dev/u26-dev/users.yaml"
packages_file = "../dev/u26-dev/packages.yaml"

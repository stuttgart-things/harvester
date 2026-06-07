# Dev playground image: u26-dev
# Self-service, auto-merged. Layered ON TOP of the golden sthings-u26 image so
# a build only installs the delta (devs' SSH keys + extra packages).
# Build runs from packer/_build/ -> paths below are relative to that dir.
#
# TODO(#93): set source_url to the PUBLISHED golden sthings-u26 artifact once the
# golden -> dev handoff is decided (artifact store vs re-export from Harvester).
# Until then this build cannot run end-to-end.
source_url      = "" # FIXME(#93): golden sthings-u26 qcow2 artifact URL
source_checksum = "none"

image_name    = "u26-dev"
users_file    = "../dev/u26-dev/users.yaml"
packages_file = "../dev/u26-dev/packages.yaml"

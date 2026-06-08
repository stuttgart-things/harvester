# Golden base image: sthings-leap (openSUSE Leap 15.6 NoCloud)
# Curated, review-gated. Built fresh from the upstream openSUSE cloud image.
# Build runs from packer/_build/ -> paths below are relative to that dir.

source_url      = "https://download.opensuse.org/repositories/Cloud:/Images:/Leap_15.6/images/openSUSE-Leap-15.6.x86_64-NoCloud.qcow2"
source_checksum = "sha256:08ffa155237137770109fcf5174a560268cf6803091a9b2cdd3199799263fe1e" # pragma: allowlist secret — pinned to the Leap 15.6 NoCloud build; refresh if upstream rebuilds it

image_name    = "sthings-leap"
users_file    = "../golden/sthings-leap/users.yaml"
packages_file = "../golden/sthings-leap/packages.yaml"

# openSUSE-specific override of the Ubuntu defaults (see packer/_build/variables.pkr.hcl).
# Leap cloud images expose an 'opensuse' login user; the shared spec already
# boots via EFI/OVMF and the default qemuargs (cidata.iso) suit Leap.
ssh_username = "opensuse"

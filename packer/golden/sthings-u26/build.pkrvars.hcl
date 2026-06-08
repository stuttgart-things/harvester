# Golden base image: sthings-u26 (Ubuntu 26.04 LTS "Resolute")
# Curated, review-gated. Built fresh from the upstream cloud image.
# Build runs from packer/_build/ -> paths below are relative to that dir.

source_url      = "https://cloud-images.ubuntu.com/resolute/current/resolute-server-cloudimg-amd64.img"
source_checksum = "file:https://cloud-images.ubuntu.com/resolute/current/SHA256SUMS"

image_name    = "sthings-u26"
users_file    = "../golden/sthings-u26/users.yaml"
packages_file = "../golden/sthings-u26/packages.yaml"

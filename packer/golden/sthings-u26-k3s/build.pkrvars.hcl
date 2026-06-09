# Golden node image: sthings-u26-k3s (Ubuntu 26.04 LTS + baked k3s airgap)
# Dedicated k3s-ready variant: the golden sthings-u26 base + STAGED k3s airgap
# artifacts (binary + images) so edge nodes boot with zero network dependency
# for the k3s core. Curated, review-gated like all golden images.
# Build runs from packer/_build/ -> paths below are relative to that dir.
#
# Layered ON TOP of the published golden sthings-u26 base (S3), like dev images,
# so this only adds the k3s delta. The golden sthings-u26 image must be built +
# published at least once before this variant can build.
source_url      = "https://artifacts.platform.sthings.lab/packer/golden/sthings-u26/sthings-u26-amd64.img"
source_checksum = "none"

image_name    = "sthings-u26-k3s"
users_file    = "../golden/sthings-u26-k3s/users.yaml"
packages_file = "../golden/sthings-u26-k3s/packages.yaml"

# Bake k3s airgap artifacts (staged only: binary + images, no service/unit).
# PIN to a version present in S3 at ${k3s_artifacts_base_url}/<version>/ —
# confirm the artifacts are uploaded there before building.
k3s_version = "v1.31.5+k3s1"

# k3s airgap images need more room than the lean 10G base.
disk_size = "20G"

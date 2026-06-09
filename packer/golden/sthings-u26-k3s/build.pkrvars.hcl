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

# Stage airgap image tarballs (images only — no binary/unit) from the flat S3
# 'images' bucket into the k3s agent images dir. Includes cilium so the CNI also
# comes up airgapped. k3s/containerd imports every tarball in the dir on start.
airgap_images_base_url = "https://artifacts.platform.sthings.lab/images"
airgap_image_tars = [
  "k3s-airgap-images-amd64.tar.zst",
  "cilium-images.tar",
]
airgap_images_dir = "/var/lib/rancher/k3s/agent/images"

# Airgap images need more room than the lean 10G base.
disk_size = "20G"

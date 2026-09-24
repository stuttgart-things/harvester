packer {
  required_plugins {
    qemu = {
      version = ">= 1.0.9"
      source  = "github.com/hashicorp/qemu"
    }
  }
}

source "qemu" "cloud_image" {
  vm_name = "${var.image_name}-amd64.img"

  iso_url      = var.source_url
  iso_checksum = var.source_checksum
  disk_image   = true

  boot_command = []

  boot_wait = "10s"

  # QEMU specific configuration
  cpus             = 2
  memory           = 4096
  accelerator      = "kvm" # use none here if not using KVM
  disk_size        = var.disk_size
  disk_compression = true

  efi_boot          = true
  efi_firmware_code = "/usr/share/OVMF/OVMF_CODE_4M.fd"
  efi_firmware_vars = "/usr/share/OVMF/OVMF_VARS_4M.fd"

  output_directory = var.output_location

  # SSH configuration so that Packer can log into the Image
  ssh_password     = "superpassword" # pragma: allowlist secret
  ssh_username     = var.ssh_username
  ssh_timeout      = var.ssh_timeout
  shutdown_command = "sudo cloud-init clean --logs --machine-id && sudo shutdown -P now"
  headless         = true

  net_device = "virtio-net"

  qemuargs = var.qemuargs
}

build {
  name    = "image_build"
  sources = ["source.qemu.cloud_image"]

  # Wait till Cloud-Init has finished setting up the image on first-boot
  provisioner "shell" {
    inline = [
      # tail is a diagnostic only; on openSUSE the log is root-only, so read it
      # with sudo and never let it fail the loop (|| true) — exit is driven solely
      # by the boot-finished marker. Keeps Ubuntu/Rocky working unchanged.
      "while [ ! -f /var/lib/cloud/instance/boot-finished ]; do echo 'Waiting for Cloud-Init...'; sudo tail -n10 /var/log/cloud-init-output.log 2>/dev/null || true; sleep 5; done"
    ]
  }

  # Prefer IPv4 for dual-stack destinations before anything reaches the network.
  # The lab RA hands out several simultaneous global IPv6 prefixes; a source
  # address from a stale one resets large transfers mid-copy while small requests
  # on the same path succeed -- container image pulls failed exactly this way on
  # 2026-09-14. Runs first so the CA fetch and the airgap staging below both
  # benefit. Set PREFER_IPV4=false to skip.
  provisioner "shell" {
    script = "prefer-ipv4.sh"
    environment_vars = [
      "PREFER_IPV4=${var.prefer_ipv4}",
    ]
  }

  # Upload the committed sthings-lab CA so the trust install needs no network
  # (Vault may be down). Only runs when ca_cert_file is set; otherwise the
  # script falls back to ca_cert_url (or skips).
  dynamic "provisioner" {
    for_each = var.ca_cert_file != "" ? [1] : []
    labels   = ["file"]
    content {
      source      = var.ca_cert_file
      destination = "/tmp/${var.ca_cert_name}"
    }
  }

  # Install the sthings-lab private CA into the image trust store + refresh it
  # (update-ca-certificates / update-ca-trust), so VMs trust *.sthings.lab out of
  # the box. Prefers the uploaded file; falls back to ca_cert_url; no-op if both
  # are empty.
  provisioner "shell" {
    script = "install-ca-cert.sh"
    environment_vars = [
      "CA_CERT_PATH=${var.ca_cert_file != "" ? "/tmp/${var.ca_cert_name}" : ""}",
      "CA_CERT_URL=${var.ca_cert_url}",
      "CA_CERT_NAME=${var.ca_cert_name}",
    ]
  }

  # Stage airgap image tarballs (k3s/rke2/cilium) into the agent images dir when
  # airgap_image_tars is non-empty. No-op otherwise. "Stage only" — images only;
  # the node wires up the engine + binary at provision time.
  provisioner "shell" {
    script = "stage-airgap-images.sh"
    environment_vars = [
      "AIRGAP_IMAGES_BASE_URL=${var.airgap_images_base_url}",
      "AIRGAP_IMAGE_TARS=${join(",", var.airgap_image_tars)}",
      "AIRGAP_IMAGES_DIR=${var.airgap_images_dir}",
    ]
  }

  # No Harvester post-processor. Registration now happens AFTER the build, in
  # two ordered CI steps: publish-base.sh puts the image in MinIO, then
  # register-image.sh points Harvester at that URL (issue #215). Harvester has
  # to be able to fetch the artifact before it is told about it, and a packer
  # post-processor cannot express that ordering — it runs inside the build,
  # before the publish step.
}

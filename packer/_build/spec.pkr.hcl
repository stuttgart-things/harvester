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
  disk_size        = "10G"
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

  post-processor "shell-local" {
    execute_command = ["bash", "-c", "{{.Vars}} {{.Script}}"]
    script          = "upload.sh"
    environment_vars = [
      "UPLOAD_TO_HARVESTER=${var.upload_to_harvester}",
      "HARVESTER_VIP=${var.harvester_vip}",
      "HARVESTER_PASSWORD=${var.harvester_password}",
      "IMAGE_NAME=${var.image_name}",
      "IMAGE_FILE=${var.output_location}/${var.image_name}-amd64.img",
      "NAMESPACE=${var.namespace}"
    ]
  }
}

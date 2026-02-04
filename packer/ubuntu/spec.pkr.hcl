packer {
  required_plugins {
    qemu = {
      version = ">= 1.0.9"
      source  = "github.com/hashicorp/qemu"
    }
  }
}

source "qemu" "ubuntu_cloud" {
  vm_name     = "${var.image_name}-amd64.img"

  iso_url      = var.ubuntu_url
  iso_checksum = var.ubuntu_checksum
  disk_image   = true

  boot_command = []

  boot_wait         = "10s"

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
  ssh_password    = "superpassword" # pragma: allowlist secret
  ssh_username    = "ubuntu"
  ssh_timeout     = "5m"
  shutdown_command = "sudo cloud-init clean --logs --machine-id && sudo shutdown -P now"
  headless        = true

  net_device        = "virtio-net"

  qemuargs = [
    ["-cdrom", "cidata.iso"]
]
}

build {
  name    = "image_build"
  sources = [ "source.qemu.ubuntu_cloud" ]

  # Wait till Cloud-Init has finished setting up the image on first-boot
  provisioner "shell" {
      inline = [
          "while [ ! -f /var/lib/cloud/instance/boot-finished ]; do echo 'Waiting for Cloud-Init...'; tail -n10 /var/log/cloud-init-output.log; sleep 5; done"
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

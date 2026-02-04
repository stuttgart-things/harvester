locals {
  users_config    = yamldecode(file(var.users_file))
  packages_config = yamldecode(file(var.packages_file))
}

source "file" "user_data" {
  content = format("#cloud-config\n%s", yamlencode({
    ssh_pwauth     = true
    package_update = true
    packages       = local.packages_config.packages
    password       = "superpassword" # pragma: allowlist secret
    chpasswd       = { expire = false }
    users = concat(
      ["default"],
      [for u in local.users_config.users : {
        name                = u.name
        groups              = try(u.groups, "sudo")
        shell               = try(u.shell, "/bin/bash")
        sudo                = try(u.sudo, "ALL=(ALL) NOPASSWD:ALL")
        ssh_authorized_keys = u.ssh_authorized_keys
      }]
    )
    runcmd = [
      ["systemctl", "enable", "--now", "qemu-guest-agent.service"]
    ]
  }))
  target = "user-data"
}

source "file" "meta_data" {
  content = <<EOF
{"instance-id":"packer-worker.tenant-local","local-hostname":"packer-worker"}
EOF
  target  = "meta-data"
}

build {
  sources = ["source.file.user_data", "source.file.meta_data"]

  provisioner "shell-local" {
    inline = ["genisoimage -output cidata.iso -input-charset utf-8 -volid cidata -joliet -r user-data meta-data"]
  }
}

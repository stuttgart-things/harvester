locals {
  users_config    = yamldecode(file(var.users_file))
  packages_config = yamldecode(file(var.packages_file))
}

source "file" "user_data" {
  content = format("#cloud-config\n%s", yamlencode({
    ssh_pwauth      = true
    package_update  = true
    package_upgrade = true
    packages        = local.packages_config.packages
    password        = "superpassword" # pragma: allowlist secret
    chpasswd        = { expire = false }
    users = concat(
      ["default"],
      [for u in local.users_config.users : merge(
        {
          name                = u.name
          groups              = try(u.groups, "sudo")
          shell               = try(u.shell, "/bin/bash")
          sudo                = try(u.sudo, "ALL=(ALL) NOPASSWD:ALL")
          ssh_authorized_keys = u.ssh_authorized_keys
        },
        # Give the designated user (default: sthings) a password in addition to
        # its keys, so it can also log in via SSH password. The hash comes from
        # CI (openssl passwd -6 of the STHINGS_PASSWORD secret); empty = key-only.
        #
        # TWO conditionals, one per type, on purpose. A single
        # `cond ? { lock_passwd = false, hashed_passwd = "…" } : {}` makes HCL
        # unify both branches to map(string), so yamlencode wrote
        # lock_passwd as the STRING "false". cloud-init tests
        # `if kwargs.get("lock_passwd", True):`, a non-empty string is truthy,
        # and it locked the hash it had just set: every image since #108
        # shipped `sthings` as `!$6$…` (harvester#265). Kept apart, each branch
        # stays single-typed and lock_passwd stays a YAML boolean.
        (u.name == var.password_user && var.sthings_password != "") ? {
          hashed_passwd = var.sthings_password
        } : {},
        (u.name == var.password_user && var.sthings_password != "") ? {
          lock_passwd = false
        } : {}
      )]
    )
    # qemu-guest-agent is a STATIC unit on Ubuntu 26.04: udev starts it as
    # soon as the hypervisor provides the virtio channel
    # (org.qemu.guest_agent.0) -- on Harvester, every VM. The packer build VM
    # has no such channel, so `systemctl enable --now` failed here in every
    # build; since #352 a cloud-init error fails the build, and the first
    # golden release after it (2026-11-19, run 44555220229) stopped on
    # "Runparts: 1 failures (runcmd)". Start it if possible, never fail on it.
    runcmd = [
      ["sh", "-c", "systemctl start qemu-guest-agent.service || echo 'qemu-guest-agent: no virtio channel in this VM; udev starts it on Harvester'"]
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

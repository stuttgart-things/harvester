output "acme_directory" {
  value = "${var.openbao_addr}/v1/${vault_mount.pki.path}/acme/directory"
}

output "acme_directory_devices" {
  value = "${var.openbao_addr}/v1/${vault_mount.pki.path}/roles/${vault_pki_secret_backend_role.devices.name}/acme/directory"
}

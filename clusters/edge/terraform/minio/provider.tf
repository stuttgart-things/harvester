provider "minio" {
  minio_server   = var.minio_server
  minio_user     = var.minio_user
  minio_password = var.minio_password
  minio_ssl      = true
  // The edge root CA, a copy of ../../edge-root-ca.crt: dagger/terraform
  // mounts only this directory, so the file has to be here. Public, and valid
  // until 2046 -- keep it identical to the original.
  minio_cacert_file = "${path.module}/edge-root-ca.crt"
}

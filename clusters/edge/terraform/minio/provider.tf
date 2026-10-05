provider "minio" {
  minio_server   = var.minio_server
  minio_user     = var.minio_user
  minio_password = var.minio_password
  minio_ssl      = true
  // The edge root CA: clusters/edge/edge-root-ca.crt, put next to this code
  // by dagger/terraform --extra-files (README.md). Public, valid until 2046.
  minio_cacert_file = "${path.module}/edge-root-ca.crt"
}

// Through the Gateway (TLS from the persistent edge CA), not in-cluster:
// Terraform runs on the workstation.
variable "minio_server" {
  type        = string
  description = "MinIO S3 API host:port"
  default     = "minio.edge-tt-test1.4sthings.tiab.ssc.sva.de:443"
}

// The three below come from ../../apps/edge-secrets-subst.enc.yaml (SOPS),
// passed as terraform.tfvars.json -- see README.md. Never in a *.tf file.
variable "minio_user" {
  type      = string
  sensitive = true
}

variable "minio_password" {
  type      = string
  sensitive = true
}

variable "cnpg_secret_key" {
  type        = string
  sensitive   = true
  description = "MINIO_CNPG_PASSWORD: the secret key of the schmetterpause-cnpg user"
}

variable "cnpg_bucket" {
  type    = string
  default = "schmetterpause-cnpg"
}

variable "cnpg_user" {
  type    = string
  default = "schmetterpause-cnpg"
}

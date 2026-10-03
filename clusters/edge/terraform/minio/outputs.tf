output "bucket" {
  value = minio_s3_bucket.cnpg.bucket
}

output "user" {
  value = minio_iam_user.cnpg.name
}

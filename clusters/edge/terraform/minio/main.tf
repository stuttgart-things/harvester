// What schmetterpause's CNPG backup needs in MinIO: the bucket, a user, and a
// policy that allows that user exactly that bucket -- instead of the root
// credentials (harvester#364, phase 1b).

// Terraform is the bucket's only owner. On edge-tt-test1 it first existed
// through the chart's `defaultBuckets` (#365) and was adopted once with an
// `import` block; that block is gone because it fails on a fresh MinIO
// ("cannot import bucket: the bucket does not exist", sthings-edge
// 2026-10-12) -- there Terraform creates the bucket. The lab state already
// holds it, so removing the block changes nothing there.
resource "minio_s3_bucket" "cnpg" {
  bucket = var.cnpg_bucket
  acl    = "private"

  // A backup bucket is not destroyed with `terraform destroy` while it has
  // objects in it.
  force_destroy = false
}

// What barman-cloud does with the bucket: list it, read/write/delete WAL
// segments and base backups, and multipart uploads for large files.
resource "minio_iam_policy" "cnpg_rw" {
  name = "${var.cnpg_bucket}-rw"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetBucketLocation", "s3:ListBucket", "s3:ListBucketMultipartUploads"]
        Resource = ["arn:aws:s3:::${var.cnpg_bucket}"]
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject", "s3:PutObject", "s3:DeleteObject",
          "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts",
        ]
        Resource = ["arn:aws:s3:::${var.cnpg_bucket}/*"]
      },
    ]
  })
}

resource "minio_iam_user" "cnpg" {
  name          = var.cnpg_user
  secret        = var.cnpg_secret_key
  update_secret = true
}

resource "minio_iam_user_policy_attachment" "cnpg" {
  user_name   = minio_iam_user.cnpg.id
  policy_name = minio_iam_policy.cnpg_rw.id
}

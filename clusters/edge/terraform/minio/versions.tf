terraform {
  required_version = ">= 1.10.0"
  required_providers {
    minio = {
      source  = "aminueza/minio"
      version = "~> 3.44"
    }
  }
}

# --- Object Storage (Hetzner S3-compatible) ---

provider "aws" {
  region     = var.location
  access_key = var.object_storage_access_key
  secret_key = var.object_storage_secret_key

  endpoints {
    s3 = "https://${var.location}.your-objectstorage.com"
  }
  skip_region_validation      = true
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
  s3_use_path_style           = true
}

resource "aws_s3_bucket" "backups" {
  bucket = var.backup_bucket_name
}

resource "aws_s3_bucket_versioning" "backups" {
  bucket = aws_s3_bucket.backups.id

  versioning_configuration {
    status = "Enabled"
  }
}

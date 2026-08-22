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

resource "aws_s3_bucket" "analytics" {
  bucket = var.analytics_bucket_name
}

resource "aws_s3_bucket_versioning" "analytics" {
  bucket = aws_s3_bucket.analytics.id

  versioning_configuration {
    status = "Enabled"
  }
}

# DOCUMENTATION ONLY — same caveat as the analytics lifecycle configuration below: this is
# not applied or reconciled by Terraform. Change it with `aws s3api`.
resource "aws_s3_bucket_lifecycle_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id

  timeouts {
    create = "10m"
    update = "10m"
  }

  lifecycle {
    ignore_changes = all
  }

  rule {
    id     = "expire-noncurrent-90d"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 90
    }
  }
}

# DOCUMENTATION ONLY — Terraform does not manage the lifecycle rules on this bucket.
#
# The AWS provider's lifecycle read/write cycle does not survive Hetzner's S3
# implementation, hence the `timeouts` and `ignore_changes = all` below: the resource is
# refreshed from the remote but never planned against, so drift is silently absorbed and
# never reported. Editing the rules here changes nothing on the bucket.
#
# Apply changes with `aws s3api put-bucket-lifecycle-configuration` instead — note that it
# REPLACES the entire configuration, so every rule must be submitted together. See
# docs/todo/raw-zone-retention.md; docs/setup/object-storage-key-rotation.md has the
# `aws s3api` + Hetzner credential pattern.
#
# The rules below mirror the deployed configuration, verified against the bucket on
# 2026-08-22. Rule-level `prefix` (deprecated in the provider) is used deliberately: it
# matches Hetzner's documented JSON shape, which wants `Prefix` rather than `Filter`.
#
# Effective retention on analytics/raw/ is ~180 days, not 90. Versioning is Enabled on this
# bucket, so `expiration` adds a delete marker at day 90 rather than deleting; the object is
# only reclaimed when expire-noncurrent-90d catches it 90 days later.
resource "aws_s3_bucket_lifecycle_configuration" "analytics" {
  bucket = aws_s3_bucket.analytics.id

  timeouts {
    create = "10m"
    update = "10m"
  }

  lifecycle {
    ignore_changes = all
  }

  rule {
    id     = "expire-noncurrent-90d"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 90
    }
  }

  # Raw zone retention. Also the disaster-recovery horizon: `run_dbt.sh --full-refresh`
  # rebuilds staging from S3, so this bounds what can be reconstructed if
  # /srv/data/analytics/analytics.duckdb is lost. Normal incremental runs need only 16 days.
  rule {
    id     = "expire-raw-analytics-90d"
    status = "Enabled"
    prefix = "analytics/raw/"

    expiration {
      days = 90
    }
  }
}

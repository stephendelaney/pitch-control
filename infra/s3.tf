# The Medallion data lake (ADR-0003): ONE private bucket, with bronze/silver/gold as
# key PREFIXES (not separate buckets). Layout: s3://<bucket>/{bronze,silver,gold}/<source>/…
# Bronze keeps raw payloads (JSON/CSV) for replay; Silver/Gold are Parquet.

locals {
  lake_bucket_name = "${var.project}-lake-${data.aws_caller_identity.current.account_id}"
  medallion_layers = ["bronze", "silver", "gold"]
}

resource "aws_s3_bucket" "lake" {
  bucket = local.lake_bucket_name

  tags = {
    Name = local.lake_bucket_name
    Role = "medallion-lake"
  }
}

# Private by default — the lake is reached via IAM (dlt write path, DuckDB read path),
# never anonymously.
resource "aws_s3_bucket_public_access_block" "lake" {
  bucket                  = aws_s3_bucket.lake.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "lake" {
  bucket = aws_s3_bucket.lake.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256" # SSE-S3, no key-management cost
    }
    bucket_key_enabled = true
  }
}

# Versioning as a cheap safety net. ADR-0003 treats Bronze as append-only and Silver/Gold
# as full-rebuild/overwrite; versioning protects against a bad overwrite. Noncurrent
# versions are expired quickly so storage doesn't creep.
resource "aws_s3_bucket_versioning" "lake" {
  bucket = aws_s3_bucket.lake.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "lake" {
  bucket = aws_s3_bucket.lake.id

  rule {
    id     = "abort-incomplete-multipart"
    status = "Enabled"
    filter {}
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  rule {
    id     = "expire-noncurrent-versions"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}

# Zero-byte prefix markers so the medallion structure is visible in the console from day one.
# dlt/dbt write the real keys underneath; these just document the layout.
resource "aws_s3_object" "layer_markers" {
  for_each = toset(local.medallion_layers)

  bucket       = aws_s3_bucket.lake.id
  key          = "${each.value}/.keep"
  content      = ""
  content_type = "text/plain"
}

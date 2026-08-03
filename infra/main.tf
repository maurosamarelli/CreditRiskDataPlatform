# ============================================================
# Random suffix — S3 bucket names must be globally unique
# ============================================================
resource "random_id" "suffix" {
  byte_length = 4
}

# ============================================================
# S3 buckets — one per Medallion layer (raw / silver / gold)
# ============================================================
locals {
  layers = ["raw", "silver", "gold"]
}

resource "aws_s3_bucket" "data_lake" {
  for_each = toset(local.layers)

  bucket = "${var.project_name}-${each.key}-${random_id.suffix.hex}"

  tags = {
    Project     = var.project_name
    Environment = var.environment
    Layer       = each.key
  }
}

resource "aws_s3_bucket_versioning" "data_lake" {
  for_each = aws_s3_bucket.data_lake

  bucket = each.value.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "data_lake" {
  for_each = aws_s3_bucket.data_lake

  bucket = each.value.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "data_lake" {
  for_each = aws_s3_bucket.data_lake

  bucket                  = each.value.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Raw layer: move older objects to cheaper storage automatically.
# Silver/gold stay on Standard since they're queried more actively.
resource "aws_s3_bucket_lifecycle_configuration" "raw_layer" {
  bucket = aws_s3_bucket.data_lake["raw"].id

  rule {
    id     = "raw-to-ia"
    status = "Enabled"

    filter {}

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }
  }
}

# ============================================================
# IAM role for Glue jobs/crawlers
# ============================================================
resource "aws_iam_role" "glue_role" {
  name = "${var.project_name}-glue-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "glue.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Project     = var.project_name
    Environment = var.environment
  }
}

# Managed policy with the baseline permissions Glue needs to run
resource "aws_iam_role_policy_attachment" "glue_service_role" {
  role       = aws_iam_role.glue_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}

# Custom policy: scoped access to only this project's buckets
# (least privilege — avoids granting access to all S3 in the account)
resource "aws_iam_role_policy" "glue_s3_access" {
  name = "${var.project_name}-glue-s3-access"
  role = aws_iam_role.glue_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket"
        ]
        Resource = flatten([
          for b in aws_s3_bucket.data_lake : [b.arn, "${b.arn}/*"]
        ])
      }
    ]
  })
}

# ============================================================
# Glue Data Catalog — database to register tables into later
# (crawlers/tables are added once there is actual data in S3)
# ============================================================
resource "aws_glue_catalog_database" "credit_risk_db" {
  name        = replace("${var.project_name}_db", "-", "_")
  description = "Data Catalog for the credit risk data platform project"
}

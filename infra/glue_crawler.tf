# ============================================================
# Glue Crawler — scans the raw S3 layer and populates the
# Data Catalog with inferred schema (one table per S3 prefix)
# ============================================================
resource "aws_glue_crawler" "raw_crawler" {
  name          = "credit-risk-raw-crawler"
  role          = aws_iam_role.glue_role.arn
  database_name = aws_glue_catalog_database.credit_risk_db.name
  table_prefix  = "raw_"

  # Two explicit targets (one per source), matching the folder
  # structure created during manual S3 upload (gmsc/, lending_club/)
  s3_target {
    path = "s3://${aws_s3_bucket.data_lake["raw"].bucket}/gmsc/"
  }

  s3_target {
    path = "s3://${aws_s3_bucket.data_lake["raw"].bucket}/lending_club/"
  }

  # On demand: no schedule block means manual trigger only.
  # Appropriate here since raw data isn't arriving continuously.

  # Once manual fixes are applied to a table (e.g. skip.header.line.count,
  # renamed columns), avoid the crawler silently overwriting them on a
  # future run — log changes instead of applying them automatically.
  schema_change_policy {
    update_behavior = "LOG"
    delete_behavior  = "LOG"
  }

  tags = {
    Project     = var.project_name
    Environment = var.environment
  }
}

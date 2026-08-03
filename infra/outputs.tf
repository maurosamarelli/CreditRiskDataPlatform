output "s3_bucket_names" {
  description = "Names of the created S3 buckets, keyed by layer"
  value       = { for k, b in aws_s3_bucket.data_lake : k => b.id }
}

output "glue_role_arn" {
  description = "ARN of the IAM role used by Glue jobs/crawlers"
  value       = aws_iam_role.glue_role.arn
}

output "glue_database_name" {
  description = "Name of the Glue Data Catalog database"
  value       = aws_glue_catalog_database.credit_risk_db.name
}

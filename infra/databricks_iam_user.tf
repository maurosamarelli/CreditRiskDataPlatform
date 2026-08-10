# ============================================================
# Dedicated IAM user for Databricks Community Edition access.
# Community Edition can't use cross-account IAM roles (that
# requires a full workspace deployment integrated with AWS),
# so access keys are the only option — scoped to least privilege.
# ============================================================
resource "aws_iam_user" "databricks_community" {
  name = "${var.project_name}-databricks-community"

  tags = {
    Project     = var.project_name
    Environment = var.environment
    Purpose     = "Databricks Community Edition notebook access"
  }
}

resource "aws_iam_user_policy" "databricks_community_s3_access" {
  name = "${var.project_name}-databricks-s3-access"
  user = aws_iam_user.databricks_community.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadOnlyRaw"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.data_lake["raw"].arn,
          "${aws_s3_bucket.data_lake["raw"].arn}/*"
        ]
      },
      {
        Sid    = "ReadWriteSilverAndGold"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket"
        ]
        Resource = flatten([
          for layer in ["silver", "gold"] : [
            aws_s3_bucket.data_lake[layer].arn,
            "${aws_s3_bucket.data_lake[layer].arn}/*"
          ]
        ])
      }
    ]
  })
}

# Access key for programmatic use from the Databricks Community Edition
# notebook. The secret is stored in Terraform state — treat the state
# file as sensitive (it already is, e.g. it also holds no other secrets
# so far, but this changes that).
resource "aws_iam_access_key" "databricks_community" {
  user = aws_iam_user.databricks_community.name
}

output "databricks_community_access_key_id" {
  description = "Access key ID for the Databricks Community Edition IAM user"
  value       = aws_iam_access_key.databricks_community.id
}

output "databricks_community_secret_access_key" {
  description = "Secret access key for the Databricks Community Edition IAM user"
  value       = aws_iam_access_key.databricks_community.secret
  sensitive   = true
}

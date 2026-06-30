output "lake_bucket" {
  description = "Medallion data-lake bucket name (bronze/silver/gold prefixes)."
  value       = aws_s3_bucket.lake.bucket
}

output "lake_bucket_arn" {
  description = "ARN of the lake bucket."
  value       = aws_s3_bucket.lake.arn
}

output "rds_endpoint" {
  description = "Postgres connection endpoint (host:port)."
  value       = aws_db_instance.postgres.endpoint
}

output "rds_address" {
  description = "Postgres hostname."
  value       = aws_db_instance.postgres.address
}

output "rds_database" {
  description = "Initial database name."
  value       = aws_db_instance.postgres.db_name
}

output "gha_deploy_role_arn" {
  description = "IAM role ARN for GitHub Actions to assume via OIDC (set as a repo secret/var: AWS_DEPLOY_ROLE_ARN)."
  value       = aws_iam_role.gha_deploy.arn
}

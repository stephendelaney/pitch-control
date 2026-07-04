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

output "tf_plan_role_arn" {
  description = "Read-only OIDC role for `terraform plan` on PRs (repo var: AWS_TF_PLAN_ROLE_ARN). ADR-0020."
  value       = aws_iam_role.tf_plan.arn
}

output "tf_apply_role_arn" {
  description = "Write OIDC role (main-pinned) for `terraform apply` + Wk-2 lake write (repo var: AWS_TF_APPLY_ROLE_ARN). ADR-0020."
  value       = aws_iam_role.tf_apply.arn
}

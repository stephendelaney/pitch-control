output "lake_bucket" {
  description = "Medallion data-lake bucket name (bronze/silver/gold prefixes)."
  value       = aws_s3_bucket.lake.bucket
}

output "lake_bucket_arn" {
  description = "ARN of the lake bucket."
  value       = aws_s3_bucket.lake.arn
}

output "tfstate_bucket" {
  description = "Remote Terraform state bucket (B6). Referenced by the `backend \"s3\"` block in backend.tf."
  value       = aws_s3_bucket.tfstate.bucket
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
  description = "Write OIDC role (main-pinned) for `terraform apply`, infra management only (repo var: AWS_TF_APPLY_ROLE_ARN). ADR-0020."
  value       = aws_iam_role.tf_apply.arn
}

output "ingest_role_arn" {
  description = "Runtime OIDC role (main-pinned) for the dlt Bronze jobs; writes bronze/* only (repo var: AWS_INGEST_ROLE_ARN). ADR-0020/0021."
  value       = aws_iam_role.ingest.arn
}

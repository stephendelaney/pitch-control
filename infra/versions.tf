# Provider + Terraform version pins. The lock file (.terraform.lock.hcl) is committed
# (see repo .gitignore) so provider versions are reproducible across machines/CI.
terraform {
  # >= 1.10 is a hard floor, not a preference: the S3 backend's `use_lockfile` (B6 —
  # S3-native locking, no DynamoDB table) was introduced in Terraform 1.10.
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

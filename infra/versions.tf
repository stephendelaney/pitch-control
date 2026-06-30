# Provider + Terraform version pins. The lock file (.terraform.lock.hcl) is committed
# (see repo .gitignore) so provider versions are reproducible across machines/CI.
terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

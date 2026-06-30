provider "aws" {
  region = var.aws_region

  # Every resource is tagged so cost/ownership is attributable and console-discoverable.
  default_tags {
    tags = {
      Project   = var.project
      Env       = var.environment
      ManagedBy = "terraform"
      Repo      = var.github_repo
    }
  }
}

# Account context used to build globally-unique names (e.g. the lake bucket)
# and IAM principals.
data "aws_caller_identity" "current" {}

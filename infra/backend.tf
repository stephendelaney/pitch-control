# State backend.
#
# Wk 1 (now): LOCAL state — terraform.tfstate on disk, gitignored. Zero setup, $0.
# This is a DELIBERATE, temporary deviation from ADR-0009 (which specifies remote
# state in S3 + locking). We defer the remote backend to Wk 5 (CI/OIDC deploys),
# at which point this block migrates to:
#
#   backend "s3" {
#     bucket       = "pitch-control-tfstate-<account-id>"
#     key          = "infra/terraform.tfstate"
#     region       = "us-east-1"
#     use_lockfile = true   # S3-native locking (no DynamoDB table needed)
#   }
#
# The S3 state bucket is the classic chicken-and-egg bootstrap noted in ADR-0009:
# create it once (by hand or a tiny bootstrap config) before Terraform manages state.
terraform {
  backend "local" {}
}

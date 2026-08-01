# State backend.
#
# B6 (2026-08-01): state moves from the laptop to S3 — ADR-0009's remote backend, pulled forward
# from Wk 5 now that the first apply has happened. The bucket is defined in `tfstate.tf`
# (versioned, encrypted, TLS-only, prevent_destroy); `use_lockfile = true` gives S3-native state
# locking, so there is no DynamoDB table to run or pay for (Terraform >= 1.10 — see versions.tf).
#
# The bucket was created on 2026-08-01 by an apply run while this block still said
# `backend "local"` — that ordering IS the chicken-and-egg resolution, and it's the only reason a
# separate bootstrap config isn't needed. If you ever rebuild this from nothing, you must do the
# same: local backend → apply → flip to `backend "s3"` → `terraform init -migrate-state`.
#
# Backend blocks cannot interpolate variables, so the bucket name is literal (account 749614773761,
# already published in this repo's docs — it is an identifier, not a credential).
# Full procedure + the teardown caveat prevent_destroy introduces: infra/README.md → "Remote state (B6)".

terraform {
  backend "s3" {
    bucket       = "pitch-control-tfstate-749614773761"
    key          = "infra/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true # S3-native locking (no DynamoDB table needed)
    encrypt      = true
  }
}

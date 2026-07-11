variable "project" {
  description = "Project slug; used as a name prefix for all resources."
  type        = string
  default     = "pitch-control"
}

variable "environment" {
  description = "Deployment environment (dev/prod). Single env for now."
  type        = string
  default     = "dev"
}

variable "aws_region" {
  description = "AWS region. us-east-1 keeps the broadest free-tier coverage."
  type        = string
  default     = "us-east-1"
}

variable "github_repo" {
  description = "owner/repo allowed to assume the GitHub Actions OIDC deploy role (ADR-0007/0009)."
  type        = string
  default     = "stephendelaney/pitch-control"
}

# --- RDS Postgres (ADR-0002) ---

variable "pg_version" {
  description = "Postgres major version. Major-only lets RDS track the latest minor."
  type        = string
  default     = "16"
}

variable "db_name" {
  description = "Initial database name created on the instance."
  type        = string
  default     = "pitchcontrol"
}

variable "db_username" {
  description = "Master username for the RDS Postgres instance."
  type        = string
  default     = "pitchadmin"
}

variable "db_password" {
  description = <<-EOT
    Master password for RDS. NO default — injected from 1Password at runtime, never on disk (ADR-0019):
      export TF_VAR_db_password=$(op read "op://pitch-control/rds-master/password")
    1Password is the source of truth; Lambdas (Wk 2+) read this from SSM SecureString seeded from it.
    Secrets Manager / RDS-managed passwords are the paid escalation ($0 constraint — bills per secret).
  EOT
  type        = string
  sensitive   = true
}

variable "budget_notification_email" {
  description = <<-EOT
    Email that receives AWS Budgets alerts (B2 cost guard). NO default — kept off-repo to avoid
    advertising a personal address in a public repo. Set it at runtime:
      export TF_VAR_budget_notification_email="you@example.com"
    (or a gitignored terraform.tfvars). First two budgets per account are free.
  EOT
  type        = string
}

variable "allowed_cidrs" {
  description = <<-EOT
    CIDRs allowed to reach Postgres on 5432. NO default — lock to your current IP, e.g.
      allowed_cidrs = ["203.0.113.4/32"]
    GitHub Actions runner IPs are dynamic and NOT added here. OIDC grants IAM credentials,
    not network reach, so the Wk-2 dlt-from-Postgres job can't ride the deploy role onto RDS.
    Per ADR-0021 the ingest workflow instead opens its own SG ingress for the runner's current
    /32 on 5432, runs, then revokes it (if: always() + a janitor for orphans) — a transient
    hole, not a standing one. In-VPC Lambda (SG-to-SG, no public exposure) is the deferred
    end-state, landing with the ADR-0015 API buildout.
  EOT
  type        = list(string)
}

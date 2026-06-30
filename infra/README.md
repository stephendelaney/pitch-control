# `infra/` — Terraform (Wk 1 skeleton)

Provisions the foundational AWS infrastructure for **pitch-control**. Declarative, versioned,
reproducible from zero (ADR-0009).

## What this stands up

| Resource | File | ADR |
|---|---|---|
| RDS Postgres `db.t4g.micro` (OLTP system of record) | `rds.tf` | [0002](../docs/adr/0002-postgres-jsonb-system-of-record.md) |
| S3 medallion lake — one bucket, `bronze/silver/gold` prefixes | `s3.tf` | [0003](../docs/adr/0003-s3-parquet-medallion-lake.md) |
| Default-VPC networking + IP-locked Postgres SG | `network.tf` | 0002 |
| GitHub Actions OIDC provider + keyless deploy role | `iam_oidc.tf` | [0007](../docs/adr/0007-github-actions-lambda-orchestration.md) / [0009](../docs/adr/0009-terraform-iac.md) |
| Seed schema (`ops.pipeline_runs`, JSONB landing) | `sql/0001_init.sql` | 0002 / 0007 / 0012 |

> **Secrets:** 1Password is the source of truth; secrets are injected at runtime via the `op` CLI and
> never written to disk (ADR-0019). Lambdas (Wk 2+) read credentials from SSM `SecureString`, seeded
> from 1Password. AWS deploy auth is keyless OIDC.

## Decisions baked in (Wk 1)

- **Local state**, not S3 — a deliberate, temporary deviation from ADR-0009. See `backend.tf`;
  reconciled in Wk 5 when CI/OIDC deploys land.
- **Default VPC, public RDS, IP-locked SG** — simplest reachable Postgres for local dev/dbt. A
  dedicated private-subnet VPC is a later upgrade.
- **$0 posture** — free-tier instance/storage; SSE-S3 (no KMS cost); no Performance Insights; no
  RDS Proxy / Secrets Manager (ADR-0002 names RDS Proxy as a non-free escalation; ADR-0019 names
  Secrets Manager as the paid secret-store escalation). 1Password is already paid → $0 marginal.

## Prerequisites

- Terraform ≥ 1.9 (v1.15.6 installed), AWS CLI authenticated to the target account.
- 1Password CLI (`op`), signed in — secrets are read from the vault, not from disk (ADR-0019).
- `psql` if you want to apply the seed schema.

## Usage

```bash
cd infra

# 1. Provide the two no-default inputs from 1Password (no secrets on disk — ADR-0019):
export TF_VAR_db_password=$(op read "op://pitch-control/rds-master/password")
export TF_VAR_allowed_cidrs='["'"$(curl -s https://checkip.amazonaws.com)"'/32"]'   # lock ingress to your IP
#   (non-secret overrides only — e.g. pg_version — may go in a gitignored terraform.tfvars)

# 2. Standard flow:
terraform init
terraform fmt -check
terraform validate
terraform plan
terraform apply

# 3. (optional) apply the seed schema to verify connectivity:
psql "postgresql://pitchadmin:$TF_VAR_db_password@$(terraform output -raw rds_address):5432/pitchcontrol" \
     -f sql/0001_init.sql
```

## Outputs

`lake_bucket`, `rds_endpoint`/`rds_address`/`rds_database`, and `gha_deploy_role_arn` (set the last
as the `AWS_DEPLOY_ROLE_ARN` repo variable for Actions in Wk 2+).

## Not here yet (by design)

- Remote S3 state + locking → Wk 5.
- Lambda functions and their **reserved-concurrency caps** (ADR-0002 amendment) → arrive with the
  API (ADR-0015) and dlt read path (ADR-0010); no Lambdas exist in Wk 1.
- Broader Terraform-deploy IAM policy for CI `apply` → Wk 5; the role currently grants only
  lake read/write (the first real use: Wk 2 dlt → Bronze).
- CloudFront/SPA (0014), API Gateway (0015), Cognito (0016) → later weeks.

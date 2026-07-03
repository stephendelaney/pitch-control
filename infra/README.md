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
- **$0 posture** — free-tier instance (`db.t4g.micro`) + `gp2` storage (the documented free-tier
  type); SSE-S3 (no KMS cost); no Performance Insights; no RDS Proxy / Secrets Manager (ADR-0002
  names RDS Proxy as a non-free escalation; ADR-0019 names Secrets Manager as the paid secret-store
  escalation). 1Password is already paid → $0 marginal.
  > ⚠️ **"$0" is credit-funded here, not structural.** This account is on the **post-July-2025
  > credits plan** (confirmed 2026-07-03), *not* the legacy 12-month free tier — so there is **no
  > 750-hour RDS allowance**. `db.t4g.micro` + 20 GB gp2 draws down credits at ~**$12–14/mo**
  > (~$75–85 over the plan's 6 months, comfortably inside the $100–$200 of credits). **Net: $0 out
  > of pocket for ~6 months, then real money** when the plan expires (6 months **or** credits
  > exhausted, whichever first). The config is minimal by construction; the *funding* is the
  > variable. Two upsides: standing up RDS + Budgets is how you *earn* the second $100 of credits,
  > and B2's Budgets alarm (below) guards the drawdown. Plan the month-6 exit (tear down / migrate
  > to an actually-free Postgres) before credits lapse.
- **TLS enforced by default — no config needed.** RDS PostgreSQL **15+** ships `rds.force_ssl = 1`
  in the default parameter group, and we run `pg_version = "16"` on that default group, so the
  instance **rejects non-TLS connections** out of the box. Do **not** add a custom parameter group
  to "turn on" SSL — it's redundant. All clients connect with `sslmode=verify-full` (see
  [Connecting (TLS)](#connecting-tls)) — encrypt *and* verify the server cert, which matters given
  the public-RDS + IP-locked-SG posture.

## Pre-flight (run before `terraform apply` — cheap CLI checks, no resources created)

Both of these guard against a **hard apply failure**. (The free-tier-regime question is **resolved**:
this account is on the post-July-2025 **credits plan** — see the $0 caveat above — so there is no
account-age check to run; the spend is credit-funded, not free-tier-covered.)

```bash
# 1. Default VPC must exist — network.tf depends on it. Empty output = hard failure at plan time.
aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[].VpcId' --output text
#   If empty: `aws ec2 create-default-vpc` (or point network.tf at a real VPC/subnets).

# 2. Only ONE GitHub OIDC provider is allowed per account — iam_oidc.tf creates one.
aws iam list-open-id-connect-providers
#   If a token.actions.githubusercontent.com provider already exists: swap the resource in
#   iam_oidc.tf for a `data "aws_iam_openid_connect_provider"` and reference its ARN (avoids
#   EntityAlreadyExists).

# (Free-tier regime — RESOLVED 2026-07-03: this account is on the post-July-2025 credits plan,
#  not the legacy 12-month tier. No age check needed; spend is credit-funded. See $0 caveat above.
#  Optional: eyeball remaining credits + plan expiry in Billing console → Free tier / Credits.)
```

## Prerequisites

- Terraform ≥ 1.9 (v1.15.6 installed), AWS CLI authenticated to the target account.
- 1Password CLI (`op`), signed in — secrets are read from the vault, not from disk (ADR-0019).
- `psql` (and/or Postico as a GUI) if you want to apply the seed schema / browse the DB.
- The **Amazon RDS CA bundle**, for `sslmode=verify-full` (see [Connecting (TLS)](#connecting-tls)):
  ```bash
  curl -sO https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem   # ~/.aws or wherever you like
  ```

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

# 3. (optional) apply the seed schema to verify connectivity (TLS-verified — see Connecting below):
psql "postgresql://pitchadmin:$TF_VAR_db_password@$(terraform output -raw rds_address):5432/pitchcontrol?sslmode=verify-full&sslrootcert=global-bundle.pem" \
     -f sql/0001_init.sql
```

## Connecting (TLS)

TLS is **enforced server-side** (pg16 default `rds.force_ssl = 1`), so every client must connect
over SSL. We standardize on **`verify-full`** — encrypt *and* verify the server certificate against
the [Amazon RDS CA bundle](https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem) — not
just `require` (which encrypts but skips the CA check). `verify-full` works because we connect via the
AWS-provided endpoint (`terraform output -raw rds_address`), which matches the cert's hostname; a CNAME
in front would break the hostname check.

- **psql** — append to the connection URL:
  `?sslmode=verify-full&sslrootcert=/path/to/global-bundle.pem`
- **Postico** — connection → SSL Mode **`verify-full`**, and point the CA Certificate at
  `global-bundle.pem`.

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

# ADR-0019: Secret management — 1Password as source of truth, SSM as runtime store

- **Status:** Accepted
- **Date:** 2026-06-30 (ratified 2026-06-30)
- **Deciders:** Stephen Delaney
- **Tags:** infra, security, secrets

## Context

The stack has secrets to handle even at Wk 1, and more arrive with the API and ingestion:

- **AWS credentials** for deploys — already solved by **GitHub OIDC** (ADR-0007/0009): no long-lived
  AWS keys exist; CI assumes a role via short-lived tokens. That is the highest-value secret and it is
  *eliminated*, not stored.
- **RDS master password** (ADR-0002) — today passed via `TF_VAR_db_password` (env var) or a gitignored
  `terraform.tfvars`. The on-disk tfvars pattern is the weakest link.
- **Runtime DB credentials for Lambda** (Wk 2+, ADR-0010 dlt / ADR-0015 API) — Lambdas can't read a
  local `TF_VAR_`; they need a credential they can fetch at runtime. This is the real gap.
- Later: third-party keys (e.g. PostHog project key, ADR-0006).

Constraints: **$0 marginal cost**, solo maintainer. The maintainer holds a paid **1Password**
subscription (sunk cost), which raises the question of using it as the project's vault.

Secret management splits into three jobs — human/local, CI, and machine-runtime-inside-AWS — and no
single tool is best at all three. 1Password is excellent as a human-facing source of truth but awkward
on the Lambda hot path (it reintroduces a long-lived service-account token and an availability
dependency in the request path). Conversely, **SSM Parameter Store `SecureString`** is IAM-native
(read via the Lambda's existing execution role, *no stored credential*), KMS-encrypted with the
default key, and free — ideal for runtime but not a human workflow.

## Decision

We will use **1Password as the canonical source of truth** for secrets (human/local workflows, and the
master copy of every secret), and **AWS SSM Parameter Store `SecureString` as the in-AWS runtime store**
for machine consumers (Lambda→RDS). The canonical value lives in 1Password and is **seeded into SSM**
by a deploy/seed step, so machines read locally from IAM-gated SSM while humans manage one source.
**AWS auth stays OIDC** (unchanged). **AWS Secrets Manager** is the documented **paid escalation** for
when automatic rotation or cross-account sharing is required.

Concretely:

- **Local / Terraform:** stop using on-disk `terraform.tfvars` for secrets. Inject from 1Password:
  `export TF_VAR_db_password=$(op read "op://pitch-control/rds-master/password")` or
  `op run --env-file=infra/.env -- terraform …` with `op://` references.
- **Runtime (Wk 2+):** Lambdas read the DB password from a `SecureString` parameter via their
  execution role. Seed it from 1Password:
  `op read "op://pitch-control/rds-master/password" | aws ssm put-parameter --name /pitch-control/dev/rds/password --type SecureString --overwrite`.

## Options considered

| Option | Pros | Cons |
|---|---|---|
| **1Password (source of truth) + SSM Parameter Store (runtime), OIDC for AWS auth (chosen)** | Uses an already-paid vault as canonical store; kills the on-disk tfvars; runtime path is IAM-native with **no stored credential** in Lambda; **$0 marginal**; one source of truth bridged into AWS | Two systems to keep in sync; a seed step to maintain |
| **1Password everywhere (incl. Lambda SDK/Connect)** | Single tool; one vault | Lambda needs a **long-lived service-account token** baked into env (visible via `lambda:GetFunctionConfiguration`, no auto-rotation) + a network call and **availability dependency** on the hot path; Connect server isn't free |
| **SSM Parameter Store only (no 1Password)** | Simplest in-AWS; free; IAM-native | No good human/local vault; secrets get hand-entered into SSM with no canonical home; doesn't use the paid 1Password sub |
| **AWS Secrets Manager** | Managed rotation, fine-grained access | **Bills per secret + per 10k API calls — violates $0**; rotation not needed at this scale yet |

## Consequences

- **Positive:** The on-disk `terraform.tfvars` secret pattern goes away; humans manage secrets in one
  familiar vault; Lambdas get credentials with zero stored secret (execution-role-gated SSM); the
  cloud-credential story stays keyless (OIDC). All $0 marginal.
- **Negative / tradeoffs:** 1Password and SSM must be kept in sync via a seed step — a small bit of
  glue and a place where drift can occur (mitigate: 1Password is always the source; re-seed, never edit
  SSM by hand). The 1Password GitHub Action path (if used in CI) introduces one long-lived
  service-account token, mildly against the OIDC "no long-lived secrets" ethos — prefer seeding SSM
  from local over putting secrets into CI at all.
- **Follow-ups:**
  - Update `infra/README.md` + `terraform.tfvars.example` to document the `op`-based local workflow and
    deprecate on-disk secret values.
  - The ADR-0002 amendment's "Secrets Manager deferred" reasoning is now formalized here (it was only a
    Terraform comment); ADR-0002 escalation is **RDS Proxy** (pooling), which is orthogonal to this.
  - Wk 2: create the `SecureString` parameter + grant the Lambda execution role `ssm:GetParameter` +
    `kms:Decrypt` (default key); add the seed step.
  - Revisit **Secrets Manager** only if rotation/cross-account becomes a real requirement.

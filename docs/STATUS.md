# Project Status

> Single source of truth for "where are we." Update this at the **end of every working session** —
> it is what lets a fresh session orient in seconds. Last updated: **2026-06-30**.

## Current phase

**Wk 1 in progress — Terraform skeleton scaffolded + reviewed, NOT yet committed or applied.** Phase 0
docs complete + decision log ratified (0001–0018 + the two 2026-06-29 amendments, all ✅ Accepted). Repo
live: **[github.com/stephendelaney/pitch-control](https://github.com/stephendelaney/pitch-control)**
(public, `main`). Project named **`pitch-control`** (local folder stays `just-for-fun`; remote name
differs deliberately). First infra code now exists in **`infra/`** (`fmt`+`validate` clean), **reviewed
2026-06-30** (dead `aws_region` data source removed; accidental real IP in `terraform.tfvars.example`
reverted to the TEST-NET placeholder) but still **uncommitted in the working tree** and **not applied**.
New: **ADR-0019 (secret management)** drafted as Proposed.

## What exists

- `docs/` knowledge base scaffolded: ADR system, SLOs + error budget, runbooks, retros.
- ADRs **0001** (record decisions) and **0002** (Postgres + JSONB) written and Accepted.
- ADRs **0003** (S3 + Parquet Medallion lake), **0004** (DuckDB engine), **0007** (GitHub Actions +
  Lambda orchestration) written and Accepted — the storage+compute bet (0003/0004) and the richest
  orchestration tradeoff (0007).
- ADR **0013** (identity stitching — the centerpiece) written and Accepted: Cognito `sub` is the one
  canonical `user_id`; app calls PostHog `identify(sub)` (anon→known merge); dbt-Silver materializes
  `dim_identity_map` as the resilient spine; Gold marts join through it (Bronze stays source-faithful).
  Includes a join contract for `mart_manager_360` + an identity-resolution-rate correctness SLI/test.
- **Game design / mechanics** now specified in [`product/game-design.md`](product/game-design.md):
  squad/lineup/scoring/transfer rules (FPL-aligned) + a table mapping each mechanic to the OLTP +
  CDP data it generates. Closes the "engineering rich, game thin" gap.
- ADR backlog **0005, 0006, 0008–0018** defined (see [`adr/README.md`](adr/README.md)); 0017
  (scoring source) and 0018 (transfer/economy model) added from the game-design spec.
- **Architecture diagrams** (Mermaid) in [`architecture/system-architecture.md`](architecture/system-architecture.md):
  whole-project C4 context + container views (experience → app → data), data flow, identity stitching,
  CI/CD, Medallion layers.
- **Full-project scope** now captured: experience layer (React SPA, Cognito) + application layer
  (API Gateway + Lambda/FastAPI) feed the OLTP + CDP. SLOs extended to the request path (golden
  signals) alongside the data path. New ADR backlog: 0014 (web app), 0015 (API), 0016 (auth).
- Note: ADR-0002 / `user-background` memory corrected — maintainer is more familiar with **Postgres**
  (not MySQL); decision unchanged.
- **ADR backlog cleared — all rationales now written.** Drafted the remaining nine as **Proposed**
  (awaiting Stephen's ratification): **0005** (dbt), **0006** (PostHog/CDP), **0008** (Metabase),
  **0009** (Terraform + OIDC), **0010** (dlt), **0011** (FPL API), **0014** (React SPA on S3+CloudFront),
  **0015** (API Gateway + Lambda/FastAPI), **0016** (Cognito — makes `sub` the canonical `user_id`,
  satisfying ADR-0013's follow-up). Every decision in the stack now has a recorded "why."

## Decision log status

| ADRs | State |
|---|---|
| 0001–0018 | ✅ Accepted — **full decision log ratified** |
| 0002, 0007 amendments (2026-06-29) | ✅ Accepted — ratified 2026-06-30 (Lambda→RDS conn mgmt; Fargate per-step overflow) |
| **0019** (secret management) | ✅ Accepted — ratified 2026-06-30. 1Password = source of truth; SSM `SecureString` = Lambda runtime store; OIDC unchanged; Secrets Manager = paid escalation. |

## Immediate next actions

> ⏭️ **NEXT SESSION STARTS HERE (`--continue` — mid-session, NOT a clean boundary):** the Wk 1
> Terraform skeleton is written in **`infra/`** and passes `fmt`+`validate`, but **Stephen has not yet
> reviewed it, it is uncommitted, and nothing is applied.** Resume by: (1) **review the `infra/` diff**
> — RDS (`rds.tf`), single medallion lake bucket (`s3.tf`, bronze/silver/gold *prefixes* per ADR-0003),
> default-VPC IP-locked SG (`network.tf`), GitHub OIDC deploy role (`iam_oidc.tf`), seed schema
> (`sql/0001_init.sql`); (2) **commit** (`git add infra/`, message drafted in last session); (3) to
> stand it up: `cp terraform.tfvars.example terraform.tfvars`, set `allowed_cidrs` to current IP
> (`curl -s https://checkip.amazonaws.com`), `export TF_VAR_db_password=…`, then `terraform plan` →
> `apply` (**creates real billable free-tier AWS resources** — Stephen runs this himself).
> Open question to confirm at review: AWS provider pinned `~> 5.0` and `pg_version = "16"` (major-only).
> NB: `terraform` **v1.15.6 installed** ✅; `gh` still not installed (SSH used for git, optional).
> Deliberate Wk-1 deviations from ADRs, both documented in `infra/README.md` + `backend.tf`: **local
> state** (not S3 per ADR-0009 → reconcile Wk 5) and **no Lambda reserved-concurrency** yet (no Lambdas
> exist in Wk 1; the ADR-0002 amendment caps land with the API/dlt). Stephen runs all git/repo + apply
> actions himself (give commands, don't execute) — see memory.

- [x] Stephen reviewed ADR-0003 / 0004 / 0007 / **0013** — noted unremarkable (accepted, no concerns), 2026-06-16.
- [x] **Ratified ADR-0012, 0017, 0018** — flipped to ✅ Accepted, 2026-06-19.
  - 0017: ingest FPL `event_points` (own only manager-level aggregation); ingest component stats too + keep a Phase 2 compute-and-reconcile engine as a learning stretch with FPL as the oracle.
  - 0018: mirror FPL transfer/economy rules; exact values stay tunable in game-design §5.
- [x] Stephen reviewed [`product/game-design.md`](product/game-design.md) — agrees with all v1 mechanics, 2026-06-19 (stays a living spec).
- [x] **Drafted the remaining nine ADRs** (0005, 0006, 0008–0011, 0014–0016) as Proposed, 2026-06-19. ADR backlog cleared.
- [x] **Stephen reviewed & ratified the final nine ADRs** (0005, 0006, 0008–0011, 0014–0016) — all
  found unremarkable, flipped to ✅ Accepted, 2026-06-19. Two clarifications captured first:
  ADR-0015 (cold-start tradeoff + keep-warm mitigation + Wk-1 keep-warm intent) and ADR-0014
  (CloudFront is load-bearing for HTTPS/TLS + private-bucket-via-OAC, not just CDN). **Decision log now
  fully Accepted.**
- [x] **`git init` + first push to GitHub** — repo live at `stephendelaney/pitch-control` (public),
  2026-06-19. Added top-level README, stack-scoped `.gitignore` (OS/editor moved to
  `~/.gitignore_global`; `.terraform.lock.hcl` committed), repo topics set.
- [x] **Drafted two operational amendments** (2026-06-29): ADR-0002 (Lambda→RDS connection
  management — reserved concurrency + handler-scoped reuse; RDS Proxy as non-free escalation) and
  ADR-0007 (Fargate as per-step compute-overflow target; 70%-of-15-min-cap leading indicator from
  `ops.pipeline_runs` as the migration trip-wire).
- [x] **Ratified both amendments** — flipped to ✅ Accepted, 2026-06-30. Both are operational
  guardrails; neither changes a chosen technology. These now feed Wk 1 (reserved concurrency on
  RDS-touching Lambdas) and Wk 3 (capacity SLIs in `ops.pipeline_runs`).
- [x] **Reviewed the `infra/` skeleton** (2026-06-30). Removed dead `aws_region` data source; reverted
  a real IP accidentally saved into `terraform.tfvars.example` (never committed — `infra/` is untracked).
  Two carry-forward items: pre-apply check `aws iam list-open-id-connect-providers` (one GitHub OIDC
  provider per account), and tighten the OIDC trust `sub` from `repo:…:*` to `…:ref:refs/heads/main`
  when the Wk-2 deploy workflow lands.
- [x] **Drafted + ratified ADR-0019 (secret management)**, 2026-06-30 — 1Password as source of truth +
  SSM `SecureString` as the Lambda runtime store; formalizes the "Secrets Manager deferred" reasoning
  that was only an `infra/` comment. Flipped to ✅ Accepted; `infra/README.md` + `terraform.tfvars.example`
  updated to the `op`-based local workflow (on-disk secret values deprecated).

## Learning tracks

Skills being practiced deliberately, not just the app output:

- **C4 modeling** (Simon Brown) — L1/L2 done; next is L3 Component diagrams for the API + ingestion.
  Track lives in [`architecture/system-architecture.md`](architecture/system-architecture.md#method-the-c4-model-simon-brown).
- **SRE for data** — SLOs/error budgets/runbooks (`docs/slo/`, `docs/runbooks/`).
- **Decision discipline** — ADRs (`docs/adr/`).

## Multi-week roadmap

- [~] **Wk 1** — Repo + Terraform skeleton (RDS Postgres, S3 medallion, IAM/OIDC); seed schema; PostHog SDK wired.
  - *In progress:* `infra/` scaffolded + `validate`-clean (2026-06-30); pending review → commit → apply. PostHog SDK is app-layer, still TODO.
- [ ] **Wk 2** — Bronze: `dlt` jobs (Postgres→S3, FPL→S3) on a GitHub Actions schedule.
- [ ] **Wk 3** — Silver/Gold with dbt-duckdb; tests + lineage; `ops.pipeline_runs`.
- [ ] **Wk 4** — Metabase dashboards on Gold + the manager-360 identity-stitching mart.
- [ ] **Wk 5+** — CI/CD polish (OIDC deploys), elementary observability, error-budget in practice, CDP cohort experiment.

## Session ritual

1. **Start:** read this file + `docs/adr/README.md`; check memory (auto-loaded).
2. **End:** update *Current phase*, *Immediate next actions*, and the date here. Then state whether
   we're at a **clean boundary** (→ start fresh next time) or **mid-decision** (→ `--resume`).

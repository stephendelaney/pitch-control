# Backlog — assessed improvements

> Output of a fresh-eyes solution review (2026-07-03, Claude Fable 5) of the decision log,
> `infra/` skeleton, architecture doc, and SLOs. Items are scoped to be **delegable to a
> 4.8-class model**: bounded, well-specified, verifiable. Two items are **decisions** and stay
> with Stephen (a model drafts the options paper; Stephen picks). Ordering within each section
> is by value-to-effort. Prune items here as they land; record outcomes in
> [`STATUS.md`](STATUS.md).

## A. Decisions needed (Stephen picks; draft the options paper first)

### A1. Wk-2 ingest network path — how does the Postgres→S3 dlt job reach RDS?

**The gap:** `infra/variables.tf` says GitHub Actions reaches RDS "via the OIDC role + (later)
VPC routing" — but OIDC grants **IAM credentials, not network reach**. RDS is public and
IP-locked to Stephen's home CIDR; GitHub-hosted runner IPs are dynamic. As sketched, the Wk-2
Postgres→S3 dlt job **cannot connect**. This blocks Wk 2 and deserves an ADR-0007/0010
amendment before that work starts.

**Options to paper out (each has a catch):**

1. **Lambda inside the default VPC** — a VPC Lambda has no route to S3/internet without NAT
   (paid). A free **S3 gateway endpoint** fixes S3; SSM `GetParameter` then needs a paid
   interface endpoint or config delivered another way.
2. **Workflow opens/closes the SG dynamically** (add runner IP → run → remove) — free and
   bounded, but ugly and adds a cleanup failure mode.
3. **Self-hosted runner** — conflicts with the automation story.

**Deliverable:** one-page options paper → Stephen decides → ADR amendment (Proposed → ratify).

### A2. Free-tier regime — is the account legacy 12-month or new credits-plan?

**The gap:** AWS replaced the legacy 12-month free tier in **July 2025**; accounts created
after ~2025-07-15 get a credits-based plan (~$100–200 over 6 months) with **no 750-hour RDS
allowance**. Pre-flight check (c) in `infra/README.md` tests *account age*, which is only the
right test for legacy accounts. On the new plan, the RDS instance burns credits at ~$12–13/mo.

**Deliverable:** Stephen confirms the account's regime (Billing console → Free tier page)
**before `terraform apply`**; then update the pre-flight block in `infra/README.md` to test
the actual regime and restate the cost math for whichever applies. (Verify the July-2025
change details against AWS docs while updating — don't trust the summary here blindly.)

## B. Delegable now (no decision required)

### B1. Repo `CLAUDE.md` — highest leverage for delegation

The operating conventions (session ritual, ADR Proposed→ratify flow, git/apply actions are
Stephen-run, $0 constraint, `sslmode=verify-full`, STATUS.md as source of truth) live in
`docs/STATUS.md` + private session memory. Distill them into a repo-root `CLAUDE.md` so any
model/session starts with the house rules. **Source material:** `docs/STATUS.md` (session
ritual §), `docs/adr/README.md`, `infra/README.md`. **Done when:** a new session can operate
correctly from `CLAUDE.md` alone without re-deriving conventions.

### B2. AWS Budgets alarm (Terraform)

Add `aws_budgets_budget` with a low threshold (e.g. $1) + email notification to
`stephen.m.delaney@gmail.com`. First two budgets are free; this directly guards the $0 goal
regardless of how A2 resolves. **Done when:** `terraform plan` shows the budget; alert fires
on forecast/actual > threshold.

### B3. Implement ADR-0020's `tf-plan`/`tf-apply` role split

Pure Terraform, no CI dependency — roles can exist before any workflow uses them. Split
`aws_iam_role.gha_deploy` into: `tf-plan` (read-only, trust `repo:<owner>/<repo>:*`) and
`tf-apply` (write, trust pinned to `…:ref:refs/heads/main` — retiring the known `repo:…:*`
wildcard footgun early). Keep the existing lake-RW policy on the appropriate role; keep
IAM-write out of `tf-apply` per ADR-0020. **Done when:** `terraform plan` clean; the apply
role's `sub` condition is `StringEquals` on the main ref (review-checklist item from
ADR-0020's Consequences).

### B4. Lake bucket policy: deny non-TLS

Add an `aws_s3_bucket_policy` on the lake denying `s3:*` when `aws:SecureTransport = false`.
Matches the verify-full posture on RDS. **Done when:** policy in plan; no effect on the
IAM-role access paths.

### B5. CI: `terraform fmt -check` + `validate` on PRs

Add `.github/workflows/terraform-check.yml` — no AWS credentials needed (validate offline:
`terraform init -backend=false`). Catches drift on every PR and stands up the workflows
skeleton Wk 2 builds on. Optional stretch: tflint. **Done when:** workflow green on a
trivial PR.

### B6. Pull remote Terraform state forward (from Wk 5 to right-after-first-apply)

Local state on one laptop orphans live AWS resources if the laptop dies. The deferred
bootstrap is tiny: one S3 state bucket + `backend "s3"` with `use_lockfile = true` (already
sketched in `infra/backend.tf`). Do it immediately after the first successful `apply`
(Stephen runs the migrate: `terraform init -migrate-state`). **Done when:** state lives in
S3; `backend.tf` comment updated; ADR-0009 deviation note in STATUS closed.

### B7. Doc fix: psql example in `infra/sql/0001_init.sql`

The example URI interpolates `$TF_VAR_db_password` into the URL — breaks on special
characters and lands the password in shell history/process list. Switch the example to
`PGPASSWORD` (or `~/.pgpass`) + URI without credentials. Mirror in `infra/README.md`
→ "Connecting (TLS)". **Done when:** no credential appears in any example URI.

### B8. Doc fix: home-IP rotation runbook line

`allowed_cidrs` locks 5432 to the current IP; an ISP rotation locks Stephen out. Document
the refresh one-liner in `infra/README.md` (re-export
`TF_VAR_allowed_cidrs` from `checkip.amazonaws.com` → `terraform apply`). **Done when:**
README has a "my IP changed" recovery snippet.

## C. Noted, not queued (fine as-is / known)

- OIDC provider `thumbprint_list` — AWS now validates against its trusted CA store; values
  are harmless boilerplate. No action.
- SLO A2 (p95 < 400ms) vs Lambda cold starts — starter SLO, keep-warm intent already recorded
  in ADR-0015. Revisit with real data (Wk 4+).
- Metabase is local-Docker, so the Ops dashboard exists only on Stephen's machine — documented
  tradeoff (ADR-0008).
- C4 L3 component diagrams — already tracked in the learning track
  (`architecture/system-architecture.md`).

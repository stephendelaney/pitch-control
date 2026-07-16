# Backlog — assessed improvements

> Output of a fresh-eyes solution review (2026-07-03, Claude Fable 5) of the decision log,
> `infra/` skeleton, architecture doc, and SLOs. Items are scoped to be **delegable to a
> 4.8-class model**: bounded, well-specified, verifiable. Two items are **decisions** and stay
> with Stephen (a model drafts the options paper; Stephen picks). Ordering within each section
> is by value-to-effort. Prune items here as they land; record outcomes in
> [`STATUS.md`](STATUS.md).

## A. Decisions needed (Stephen picks; draft the options paper first)

### A1. Wk-2 ingest network path — how does the Postgres→S3 dlt job reach RDS? — ✅ RESOLVED 2026-07-04

**The gap:** `infra/variables.tf` says GitHub Actions reaches RDS "via the OIDC role + (later)
VPC routing" — but OIDC grants **IAM credentials, not network reach**. RDS is public and
IP-locked to Stephen's home CIDR; GitHub-hosted runner IPs are dynamic. As sketched, the Wk-2
Postgres→S3 dlt job **cannot connect**. This blocks Wk 2.

**Resolution:** drafted as **[ADR-0021](adr/0021-ci-ingest-network-path.md)** and **ratified ✅
2026-07-04**. Chosen: **option 2 — the workflow opens/closes the SG ingress itself** (authorize the
runner's current /32 on 5432 → dlt runs on the GitHub-hosted runner → `if: always()` revoke, with a
start-of-run sweep + scheduled janitor for orphans). SG grant/revoke is a narrow, RDS-SG-scoped
policy on the **runtime ingest role** (ADR-0020, not `tf-apply`). $0, no new standing infra; TLS
`verify-full` holds on every path. In-VPC Lambda (option 1, SG-to-SG) is the end-state — deferred to
the ADR-0015 API buildout, where the paid-SSM-interface-endpoint cost gets decided once for both
consumers. **Triggered follow-ups (not yet done):** runbook `runbooks/orphaned-sg-rule.md`; refresh
the `allowed_cidrs` comment in `infra/variables.tf` + the A1 note in `infra/README.md`; the ingest
role joins the shared runtime exec role (ADR-0020, split-on-divergence).

### A2. Free-tier regime — is the account legacy 12-month or new credits-plan? — ✅ RESOLVED 2026-07-03, **corrected 2026-07-14 by the first apply**

**The gap:** AWS replaced the legacy 12-month free tier in **July 2025**; accounts created
after ~2025-07-15 get a credits-based plan (~$100–200 over 6 months) with **no 750-hour RDS
allowance**. Pre-flight check (c) in `infra/README.md` tested *account age*, which is only the
right test for legacy accounts.

**Resolution:** Stephen confirmed the account is on the **post-July-2025 credits plan** (6-month
free plan). Facts verified against AWS docs: $100 signup credit + up to $100 from activities
(EC2/RDS/Lambda/Bedrock/Budgets); plan expires at **6 months or credit exhaustion, whichever
first**; **no 750-hour RDS allowance**. Cost math: `db.t4g.micro` + 20 GB gp2 ≈ **$12–14/mo**
(~$75–85 over 6 months, inside the credits). `infra/README.md` updated (age check removed; cost
caveat + credits framing restated).

**⚠️ Correction (2026-07-14) — the first `terraform apply` disproved half of the above.** The apply
failed with **`FreeTierRestrictionError`** on `backup_retention_period = 7`; dropping retention
**7→1** fixed it (`infra/rds.tf`, committed `57eb74c`). The account is not merely "on a credits plan
with no limitations" — it is the restricted post-2025 **Free *plan***, which **enforces caps and
cannot silently incur charges**. It rejects out-of-cap resources at create time rather than billing
for them.

**What this changes:** the month-6 framing is **not** "then real money" — it is a **hard stop**.
At 6 months or credit exhaustion (whichever first), the plan lapses and the decision is *explicit*:
upgrade to the Paid Plan, or exit. Nothing starts quietly charging. The B2 net budget still works as
the tripwire; the B9 gross budget still watches burn rate.

**Deadline pinned (Billing console, 2026-07-16): free access ends `2026-12-11`** — $139.26 credits
remaining, 150 days. **The date binds, not the credits.** At the ~$12–14/mo RDS burn, the remaining
148 days cost ≈ **$64**, leaving ~$75 of credit unspent at expiry — so "whichever comes first"
resolves to the **calendar**. Credits only become the binding constraint above ≈ **$28.6/mo**
($139.26 ÷ 4.87 months), i.e. roughly double current burn. **B9's $15/mo gross budget is the
early-warning line for that** — it fires with months of runway left, while B2's $1 net budget stays
silent until the plan actually lapses. Re-check the break-even if Wk 2–5 adds anything non-free.

**Follow-up (unchanged in substance, sharper in framing):** plan the **month-6 exit** — tear down,
upgrade deliberately, or migrate to an actually-free Postgres (Neon/Supabase free tier, or Aurora
Serverless v2 min-capacity) — **before `2026-12-11`**. Decide by ~**Nov 2026** so the migration
isn't done under deadline. Tracks as a Wk-5+ roadmap item. `STATUS.md` and the
`aws-credits-plan-funding` memory carry the correction + the date.

## B. Delegable now (no decision required)

### B1. Repo `CLAUDE.md` — highest leverage for delegation — ✅ DONE 2026-07-03 (`62e2c4f`)

The operating conventions (session ritual, ADR Proposed→ratify flow, git/apply actions are
Stephen-run, $0 constraint, `sslmode=verify-full`, STATUS.md as source of truth) live in
`docs/STATUS.md` + private session memory. Distill them into a repo-root `CLAUDE.md` so any
model/session starts with the house rules. **Source material:** `docs/STATUS.md` (session
ritual §), `docs/adr/README.md`, `infra/README.md`. **Done when:** a new session can operate
correctly from `CLAUDE.md` alone without re-deriving conventions.

**Outcome:** `CLAUDE.md` at repo root — scoped to the *public, repo-relevant* subset of the house
rules (personal context stays in private memory by design). Cost posture restated as credits-plan
(post-A2), not $0-structural. Separate durability step: back up the private memory dir (not repo).

### B2. AWS Budgets alarm (Terraform) — ✅ DONE 2026-07-04

Add `aws_budgets_budget` with a low threshold (e.g. $1) + email notification to the maintainer's
address. First two budgets are free; this directly guards the $0 goal
regardless of how A2 resolves. **Done when:** `terraform plan` shows the budget; alert fires
on forecast/actual > threshold.

**Outcome:** `infra/budgets.tf` — `${project}-monthly-cost`, $1/mo COST budget, ACTUAL +
FORECASTED email notifications to `budget_notification_email` (new var, **no default** — set via
`TF_VAR_budget_notification_email`, kept off-repo so no personal email is committed to the public
repo). Default cost types (credits **included**) make it fire when *out-of-pocket* spend
starts — so the $1 alarm doubles as the credit-exhaustion / month-6 exit tripwire (stays quiet
while credits cover the ~$13/mo RDS drawdown). `fmt`+`validate` clean; not yet applied.

### B3. Implement ADR-0020's `tf-plan`/`tf-apply` role split — ✅ DONE 2026-07-04

Pure Terraform, no CI dependency — roles can exist before any workflow uses them. Split
`aws_iam_role.gha_deploy` into: `tf-plan` (read-only, trust `repo:<owner>/<repo>:*`) and
`tf-apply` (write, trust pinned to `…:ref:refs/heads/main` — retiring the known `repo:…:*`
wildcard footgun early). Keep the existing lake-RW policy on the appropriate role; keep
IAM-write out of `tf-apply` per ADR-0020. **Done when:** `terraform plan` clean; the apply
role's `sub` condition is `StringEquals` on the main ref (review-checklist item from
ADR-0020's Consequences).

**Outcome:** `infra/iam_oidc.tf` — `gha_deploy` split into `${project}-tf-plan` (read-only,
`StringLike sub repo:…:*`) and `${project}-tf-apply` (write, **`StringEquals` sub
`repo:…:ref:refs/heads/main`**). lake-RW attached to `tf-apply` (main-pinned write identity),
with a comment that it migrates to the dedicated runtime exec role when that lands (ADR-0019/0020
Wk-2 follow-up) so dlt and `terraform apply` don't share a role long-term. No IAM-write on either.
`outputs.tf`: `gha_deploy_role_arn` → `tf_plan_role_arn` + `tf_apply_role_arn`
(repo vars `AWS_TF_PLAN_ROLE_ARN` / `AWS_TF_APPLY_ROLE_ARN`). `fmt`+`validate` clean.

### B4. Lake bucket policy: deny non-TLS — ✅ DONE 2026-07-04

Add an `aws_s3_bucket_policy` on the lake denying `s3:*` when `aws:SecureTransport = false`.
Matches the verify-full posture on RDS. **Done when:** policy in plan; no effect on the
IAM-role access paths.

**Outcome:** `infra/s3.tf` — `aws_s3_bucket_policy.lake` with a Deny-only `DenyInsecureTransport`
statement (`Bool aws:SecureTransport = false`) over the bucket + objects. Deny-only ⇒ not a
"public" policy, so it coexists with `block_public_policy = true`; `depends_on` the public-access
block for explicit ordering. `fmt`+`validate` clean; not yet applied.

### B5. CI: `terraform fmt -check` + `validate` on PRs — ✅ DONE 2026-07-11

Add `.github/workflows/terraform-check.yml` — no AWS credentials needed (validate offline:
`terraform init -backend=false`). Catches drift on every PR and stands up the workflows
skeleton Wk 2 builds on. Optional stretch: tflint. **Also fold in the CI `gitleaks` scan**
(ADR-0022 layer 3 / B10) — a full-history secret scan job in the same workflow, no creds needed.
**Done when:** workflow green on a trivial PR; gitleaks job present.

**Outcome:** `.github/workflows/terraform-check.yml` on `pull_request`→main + `push`→main,
`permissions: contents: read`. Two independent jobs: (1) **terraform** — `fmt -check -recursive`
(covers `sql/`), `init -backend=false`, `validate`, on pinned Terraform `1.9.8` via
`setup-terraform@v3`, `working-directory: infra`; (2) **gitleaks** — full-history scan
(`fetch-depth: 0`), binary pinned to **v8.21.2** (parity with the pre-commit hook), downloaded
directly rather than via the marketplace action (avoids its org-license/telemetry path; CLI is
Apache-2.0), `detect --redact --exit-code 1`. This closes ADR-0022 layer 3's CI half (the
push-protection toggle is still Stephen's manual step). Validated locally: `fmt -check` + `validate`
clean; gitleaks asset URL returns 200; YAML parses. Not yet exercised on a live PR (no push yet).

### B6. Pull remote Terraform state forward (from Wk 5 to right-after-first-apply)

Local state on one laptop orphans live AWS resources if the laptop dies. The deferred
bootstrap is tiny: one S3 state bucket + `backend "s3"` with `use_lockfile = true` (already
sketched in `infra/backend.tf`). Do it immediately after the first successful `apply`
(Stephen runs the migrate: `terraform init -migrate-state`). **Done when:** state lives in
S3; `backend.tf` comment updated; ADR-0009 deviation note in STATUS closed.

### B7. Doc fix: psql example in `infra/sql/0001_init.sql` — ✅ DONE 2026-07-04

The example URI interpolates `$TF_VAR_db_password` into the URL — breaks on special
characters and lands the password in shell history/process list. Switch the example to
`PGPASSWORD` (or `~/.pgpass`) + URI without credentials. Mirror in `infra/README.md`
→ "Connecting (TLS)". **Done when:** no credential appears in any example URI.

**Outcome:** both the `sql/0001_init.sql` header and `infra/README.md` Usage step 3 now use
`PGPASSWORD="$TF_VAR_db_password" psql "postgresql://pitchadmin@…"` (password out of the URL; a
var reference, so the literal never hits history) + a `~/.pgpass` note. No credential in any URI.

### B8. Doc fix: home-IP rotation runbook line — ✅ DONE 2026-07-04

`allowed_cidrs` locks 5432 to the current IP; an ISP rotation locks Stephen out. Document
the refresh one-liner in `infra/README.md` (re-export
`TF_VAR_allowed_cidrs` from `checkip.amazonaws.com` → `terraform apply`). **Done when:**
README has a "my IP changed" recovery snippet.

**Outcome:** new `infra/README.md` section "My IP changed — I can't reach Postgres": re-export
`TF_VAR_allowed_cidrs` from `checkip.amazonaws.com` + `TF_VAR_db_password` from `op`, then
`terraform apply` (SG-ingress-only change). Notes runner IPs still stay out (that's A1).

### B9. Second budget: gross-drawdown watch (credit burn-rate)

The B2 alarm counts credits (`include_credit = true`), so it stays silent while credits absorb
spend and only fires once out-of-pocket money starts — by design, but it gives **zero visibility
into how fast credits are burning**. A runaway resource could drain the ~$100–200 in weeks and
the first signal would be the $1 tripwire *after* the money is gone. The second free budget slot
(first two budgets per account are free) can watch **gross** spend: add a second
`aws_budgets_budget` in `infra/budgets.tf` with `cost_types { include_credit = false }` and a
limit just above the expected burn (~$15/mo for RDS + noise), same ACTUAL + FORECASTED email
notifications to `budget_notification_email`. Quiet in a normal month; fires when drawdown
exceeds the plan — i.e. it catches cost anomalies *while credits still mask them*. **Done when:**
`terraform plan` shows both budgets; the gross budget excludes credits; still $0 (≤2 budgets).

**Outcome (✅ DONE 2026-07-11):** `infra/budgets.tf` — second budget `${project}-monthly-gross`,
$15/mo COST, `cost_types { include_credit = false, include_refund = true }`, same ACTUAL +
FORECASTED email notifications. Two budgets total = still free. `fmt`+`validate` clean; not yet
applied.

### B10. Secret/PII leakage gate — harden before Wk-2 sensitive commits (ADR-0022)

Stay-public decision (ADR-0022) is **gated** on defense-in-depth against accidentally committing a
secret value or PII to the public repo. `.gitignore` (layer 1) already covers env/secret/data
artifacts. Land the rest: **layer 2 (local gate)** — `.pre-commit-config.yaml` with `gitleaks` +
`detect-private-key` + `check-added-large-files` *(✅ committed with the ADR)*; **layer 3 (backstops)**
— GitHub secret scanning + **push protection** (repo Settings; free on public) **and** a CI `gitleaks`
job (fold into **B5**); **layer 4 (response)** — `docs/runbooks/secret-leak-response.md` (rotate-first,
then purge) *(✅ committed with the ADR)*; **PII convention** — synthetic fixtures only, own FPL entry
never committed. **Manual (Stephen):** `pre-commit install`; enable push protection. **Done when:** a
test commit containing a fake secret is blocked locally *and* by push protection; CI gitleaks job green.
Timing: **before Wk 2** (dlt real data + DB password in env).

**Status 2026-07-11:** layer 1 ✅, layer 4 ✅ (both committed with ADR-0022). Layer 3 **✅ complete** —
GitHub **secret scanning + push protection both enabled** (verified via
`gh api repos/…/… --jq .security_and_analysis`: both `enabled`) and the CI `gitleaks` job landed with
**B5** (green on `dcf2a93`). Layer 2 (local): `.pre-commit-config.yaml` committed **and now installed ✅
2026-07-11** — `brew install pre-commit` (4.6.0, brew not pipx so it's on the GitHub Desktop GUI
PATH) + `pre-commit install`; `pre-commit run --all-files` green. Commit from the Terminal for
guaranteed coverage (the hook is commit-time; a Desktop push doesn't run it — push protection covers
that). **All four ADR-0022 layers now live — B10 complete.**

## C. Noted, not queued (fine as-is / known)

- OIDC provider `thumbprint_list` — AWS now validates against its trusted CA store; values
  are harmless boilerplate. No action.
- SLO A2 (p95 < 400ms) vs Lambda cold starts — starter SLO, keep-warm intent already recorded
  in ADR-0015. Revisit with real data (Wk 4+).
- Metabase is local-Docker, so the Ops dashboard exists only on Stephen's machine — documented
  tradeoff (ADR-0008).
- C4 L3 component diagrams — already tracked in the learning track
  (`architecture/system-architecture.md`).

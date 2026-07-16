# Project Status

> Single source of truth for "where are we." Update this at the **end of every working session** —
> it is what lets a fresh session orient in seconds. Last updated: **2026-07-16**.

## Current phase

**Wk 1 COMPLETE + loose ends closed (2026-07-16) — Wk 2 is the next real move.** The `rds.tf`
retention fix landed (`57eb74c`); working tree clean. This session cleared the three delegable
leftovers (**all committed + pushed — `b9ce694`, CI green**): (1) **A2 corrected in
`backlog.md`** — the account is the restricted post-2025 **Free *plan*** (enforces
`FreeTierRestrictionError`, can't silently bill), not "credits, then real money"; (2) new runbook
**`runbooks/orphaned-sg-rule.md`** — the ADR-0021 follow-up, covering the ephemeral-SG cleanup
failure mode Wk 2 introduces; (3) **CI action bumps** — `actions/checkout@v4→v7` +
`hashicorp/setup-terraform@v3→v4` — **verified on CI run `29494537600`**: the run resolved
`checkout@v7` + `setup-terraform@v4` and the Node 20 deprecation warnings are gone from the logs.

**💰 FREE-PLAN DEADLINE PINNED (Billing console, 2026-07-16): free access ends `2026-12-11`** —
$139.26 credits remaining, 150 days. **The date binds, not the credits:** at the ~$12–14/mo RDS burn
the remaining 148 days cost ≈$64, leaving ~$75 unspent at expiry. Credits only become binding above
≈**$28.6/mo** (~2× current burn) — **B9's $15/mo gross budget is the early-warning line**; B2's $1
net budget stays silent until the plan actually lapses. **Month-6 exit → decide by ~Nov 2026**
(tear down / migrate to actually-free Postgres / upgrade to Paid Plan deliberately).

**OIDC repo variables ✅ set 2026-07-16** (`AWS_TF_PLAN_ROLE_ARN` + `AWS_TF_APPLY_ROLE_ARN`,
verified against live IAM) — **Wk 2's hard gate is cleared**. **One Stephen-run item remains:**
**B6 remote state**, now unblocked (20 live resources tracked only in local state on one laptop).

**🛑 RDS STOPPED 2026-07-16** (holiday) — **AWS force-starts a stopped instance after 7 days, so it
self-restarts ≈`2026-07-23`** and resumes drawing instance-hours unattended. A running instance
after that date is *expected*, not drift. Stopping pauses instance-hours (~$11/mo) but **storage
keeps drawing** (20 GB gp2 + backups, ~$2.30/mo) — the week saves ≈$2.60. Note this saves credits
that would **expire unused anyway** (the date binds, not the credits — see above), so it's hygiene,
not runway. No Terraform impact: `aws_db_instance` doesn't track running state, so `plan` stays
clean — but don't `apply` while stopped (some modifications need a running instance). For a longer
pause, `terraform destroy` is the real lever (deletion_protection off, skip_final_snapshot on).

<details><summary>Prior phase — Wk 1 applied + verified (2026-07-14)</summary>

**Wk 1 COMPLETE — infra applied + verified 2026-07-14.** `terraform apply` succeeded (20 resources:
RDS Postgres, S3 medallion lake, OIDC `tf-plan`/`tf-apply` roles, IP-locked SG, B2+B9 budgets).
Seed schema (`sql/0001_init.sql`) loaded over TLS `verify-full` — end-to-end connectivity proven
(1Password creds → IP-locked SG → `rds.force_ssl=1` → cert-verified `psql`). **Account/AWS auth
established this session:** IAM user `stephendelaney_IAM` (acct `749614773761`), `op` CLI signed in
(desktop-app integration), RDS master password created at `op://pitch-control/rds-master/password`.
Outputs live: lake `pitch-control-lake-749614773761`; RDS
`pitch-control-pg.c0lwc826eflz.us-east-1.rds.amazonaws.com:5432`/db `pitchcontrol`; both OIDC role
ARNs. **⚠️ A2 CORRECTION:** the first apply threw `FreeTierRestrictionError` on
`backup_retention_period = 7` — the account is the restricted post-2025 **Free *plan*** (enforces
caps, can't silently incur charges), not merely "credits, no limitations." Fixed by dropping
retention **7→1** (`rds.tf`, since committed as `57eb74c`). See A2 note below.

<details><summary>Prior phase — Wk 1 skeleton (pre-apply), retained for history</summary>

**Wk 1 in progress — Terraform skeleton reviewed + committed + pushed; NOT yet applied.** Phase 0
docs complete + decision log ratified (0001–**0020**, all ✅ Accepted). Repo live:
**[github.com/stephendelaney/pitch-control](https://github.com/stephendelaney/pitch-control)**
(public, `main`). Project named **`pitch-control`** (local folder stays `just-for-fun`; remote name
differs deliberately). Infra in **`infra/`** is `fmt`+`validate` clean, **reviewed 2026-06-30** (dead
`aws_region` data source removed; accidental real IP in `terraform.tfvars.example` reverted to the
TEST-NET placeholder), and **committed + pushed** (`339aa63`). Still **not applied** — no billable AWS
resources exist yet. **ADR-0019 (secret management)** ratified: 1Password = source of truth, SSM
`SecureString` = Lambda runtime store; infra docs moved to the `op`-based, no-secrets-on-disk workflow.
**Second pre-flight review 2026-07-02 (committed `687699d`):** added two apply-blocker
checks to pre-flight (default-VPC existence; account-age → $0 is 12-month, not always-free) + config
tweaks — RDS storage `gp3 → gp2` (documented free-tier type) and S3 lifecycle `depends_on` versioning.
Follow-up (committed `1d059b3`): documented that **TLS is enforced by the pg16 default**
(`rds.force_ssl=1`) and standardized clients on `sslmode=verify-full` + the RDS CA bundle — no infra
change, docs only (`infra/README.md`, `infra/sql/0001_init.sql`, `docs/STATUS.md`).
**ADR-0020 (IAM authorization model)** drafted, merged via PR #1 (`acbc358`) and **ratified ✅
2026-07-03**: one role per compute identity across three trust boundaries (`tf-plan` read-only/any-ref
+ `tf-apply` write/`main`-pinned in CI; one shared runtime exec role, split-on-divergence; Cognito for
clients). Terraform role-split lands with the Wk-2 deploy workflow (alongside the existing OIDC `sub`
tightening carry-forward).
**Solution review 2026-07-03** (fresh-eyes, full skeleton + docs): output captured in
[`backlog.md`](backlog.md) — **two decisions for Stephen** (A1: the Wk-2 dlt→RDS network path is
currently unresolved — OIDC grants IAM creds, not network reach; **A2: ✅ RESOLVED 2026-07-03** —
account is on the **post-July-2025 credits plan**, not the legacy 12-month tier: no 750-hr RDS
allowance, so RDS draws down credits at ~$12–14/mo — **$0 out of pocket for ~6 months, then real
money**; `infra/README.md` cost/pre-flight blocks updated; new non-blocking follow-up = plan the
month-6 exit to an actually-free Postgres) plus eight delegable hardening/doc tasks (B1–B8; B3
supersedes "role-split lands Wk 2" above — it can land now).
**B1 ✅ DONE 2026-07-03 (`62e2c4f`):** repo-root `CLAUDE.md` — public/repo-scoped house rules
(session ritual, ADR flow, maintainer-runs-git/apply, credits-plan cost posture, secrets-off-disk,
RDS `verify-full`, IAM role split); personal context stays in private memory. Follow-up (not repo):
back up the private memory dir for durability.
**Pre-apply hardening bundle ✅ DONE 2026-07-04 (committed + pushed `f105681`):** folded the
apply-time backlog items into the tree so the *first* `apply` already includes them.
**B2** — `infra/budgets.tf`: $1/mo AWS Budgets COST alarm (ACTUAL + FORECASTED email); credits
counted, so it fires when out-of-pocket spend begins → doubles as the month-6 credit-exhaustion
tripwire. **B3** — `infra/iam_oidc.tf`: ADR-0020 role split — `tf-plan` (read-only, any ref) +
`tf-apply` (write, **`StringEquals` `…:ref:refs/heads/main`**, retiring the wildcard footgun);
lake-RW on `tf-apply` for now (migrates to the runtime exec role in Wk 2); outputs →
`tf_plan_role_arn` + `tf_apply_role_arn`. **B4** — `infra/s3.tf`: `DenyInsecureTransport` bucket
policy (deny `s3:*` when `aws:SecureTransport=false`), matching the RDS verify-full posture.
**B7/B8** — doc fixes: psql example uses `PGPASSWORD` + credential-free URI (`sql/0001_init.sql`,
`README.md`); README has a "my IP changed" SG-refresh runbook. All `fmt`+`validate` clean; **not
applied**. Backlog B2/B3/B4/B7/B8 marked done — **and now B5 + B9 (2026-07-11, see below)**.
Remaining delegable: **B6** (remote state, post-apply only).
Decision **A1** (Wk-2 dlt→RDS network path) — **RESOLVED 2026-07-04 by
[ADR-0021](adr/0021-ci-ingest-network-path.md) (✅ Accepted, ratified 2026-07-04)**:
workflow-managed ephemeral SG ingress (runner /32, `always()` revoke + janitor) for Wk 2; in-VPC
Lambda deferred to the ADR-0015 buildout, where the paid-SSM-endpoint question must be decided anyway.
**Repo strategy decided 2026-07-04 — [ADR-0022](adr/0022-public-repo-strategy.md) (✅ Accepted,
ratified 2026-07-04):** stay public + build in public (the visible rationale→implementation journey is the
asset); the "finished product" is a **Wk-5+ Jekyll Pages showcase layered on top**, not a private-repo
reveal. Motivation for the split idea was secret/PII leakage — but the 1Password vault isn't exposed
(ADR-0019, `op` at runtime), so the real risk is an *accidental value/PII commit* to a public repo
(= indexed the instant it's pushed). Answer is a **defense-in-depth gate before Wk 2**, tracked as new
backlog **B10**: layer 1 `.gitignore` (already strong) + **layer 2 `.pre-commit-config.yaml`**
(`gitleaks` + `detect-private-key` + `check-added-large-files`) + layer 3 GitHub push protection & a CI
`gitleaks` job (fold into **B5**) + **layer 4 `runbooks/secret-leak-response.md`** (rotate-first,
then purge) + PII convention (synthetic fixtures only). **Committed + pushed 2026-07-04 (`d9bff51`):**
pre-commit config, leak-response runbook, ADR-0022 (✅ Accepted), CLAUDE.md house rule, index/backlog.
**Leakage gate — server side ✅ 2026-07-11:** GitHub **secret scanning + push protection both
enabled** (verified via `gh api …/security_and_analysis` — both `enabled`); with the CI `gitleaks`
job (B5) that completes ADR-0022 layer 3. **One B10 item remains:** the *local* pre-commit hook is
**✅ INSTALLED 2026-07-11** — `brew install pre-commit` (4.6.0) + `pre-commit install`; hook at
`.git/hooks/pre-commit`, `pre-commit run --all-files` green (all three hooks pass). Installed via
brew (not pipx) so the binary is on the GitHub Desktop GUI PATH too; note the hook is commit-time
(a Desktop *push* doesn't run it — push protection covers that), so commit from the Terminal for
guaranteed coverage. **This closes the last B10 item — ADR-0022's leakage gate is now complete
across all four layers.**
**Delegable CI/cost bundle ✅ DONE 2026-07-11 (committed + pushed `dcf2a93`; first CI run green):** **B5** —
`.github/workflows/terraform-check.yml`: two-job CI backstop, no AWS creds. Job 1 `terraform`
(`fmt -check -recursive` + `init -backend=false` + `validate`, pinned TF `1.9.8`); job 2 `gitleaks`
full-history scan (binary pinned **v8.21.2** = pre-commit parity, direct download not the
marketplace action) — this is ADR-0022 layer-3's CI half (push-protection toggle still manual).
Runs on PR→main + push→main, `permissions: contents: read`. **B9** — `infra/budgets.tf`: second
budget `${project}-monthly-gross`, $15/mo, `include_credit = false` (gross-drawdown watch that fires
while credits still mask spend from the B2 net budget); two budgets = still free. Pushed via GitHub
Desktop (the CLI HTTPS token lacked the `workflow` scope needed to push `.github/workflows/`).
**First CI run green** — both jobs pass (`gitleaks` 3s, `fmt+validate` 18s). Low-pri follow-up: CI
logs warn `actions/checkout@v4` + `setup-terraform@v3` run on forced Node 24 (Node 20 deprecation) —
bump action versions when convenient, non-blocking *(done 2026-07-16 — v7 / v4)*. Remaining
delegable: **B6** (remote state, post-apply only).

</details>

</details>

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
| **0020** (IAM authorization model) | ✅ Accepted — ratified 2026-07-03 (merged via PR #1). One role per compute identity; `tf-plan`/`tf-apply` CI split (Wk-2 Terraform follow-up); shared runtime exec role, split-on-divergence. |
| **0021** (Wk-2 ingest network path — A1) | ✅ Accepted — ratified 2026-07-04. Workflow-managed ephemeral SG ingress (runner /32 → run → `always()` revoke + janitor) for Wk 2; in-VPC Lambda (SG-to-SG) deferred to the ADR-0015 buildout where the paid-SSM-endpoint cost is decided. |
| **0022** (public-repo strategy) | ✅ Accepted — ratified 2026-07-04. Stay public + build in public; Wk-5+ Jekyll Pages showcase layered on top (not a private-repo reveal); enabled by a secret/PII leakage gate before Wk 2 (B10). |

## Immediate next actions

> ⏭️ **NEXT SESSION STARTS HERE (clean boundary):** **Wk 1 is applied + verified and its loose ends
> are closed.** Everything from 2026-07-16 is **committed + pushed; working tree clean** (`b9ce694`
> = the three delegable items, `2164585` = the repo-variable status update). **B6 is the only open
> item — start there, then Wk 2.**
>
> 1. ~~**Commit this session's three delegable items**~~ — **✅ DONE 2026-07-16** (`b9ce694`, pushed
>    via GitHub Desktop as it touched `.github/workflows/`). **CI green and the bumps are verified**
>    (run `29494537600` resolved `checkout@v7` + `setup-terraform@v4`; Node 20 warnings gone).
>
> 2. ~~**Set the two OIDC repo variables**~~ — **✅ DONE 2026-07-16**, verified against live IAM:
>    `AWS_TF_PLAN_ROLE_ARN` + `AWS_TF_APPLY_ROLE_ARN` are set as **repo variables** (not secrets —
>    role ARNs aren't secret and are already published in this repo). Wk 2's hard gate is cleared;
>    the ingest workflow can `role-to-assume: ${{ vars.AWS_TF_PLAN_ROLE_ARN }}` etc.
>    **NB — deviation from CLAUDE.md:** the house rule says the maintainer runs all repo/GitHub
>    actions; Stephen explicitly directed this one in-session ("set the repo variables now before I
>    forget"). Reversible via `gh variable delete <NAME> -R stephendelaney/pitch-control`.
>
> 3. **(recommended, now unblocked) B6 — migrate state to S3.** 20 live resources are tracked only
>    in local state on one laptop; the deferral's precondition ("after first apply") is met. Small:
>    add the state bucket + flip `backend.tf`, then Stephen runs `terraform init -migrate-state`.
>
> **Then start Wk 2 — Bronze ingestion (`dlt`).** FPL→S3 + Postgres→S3 on a GitHub Actions
> schedule, using ADR-0021's ephemeral-SG ingress (runner /32 opened at run, revoked via
> `always()` + janitor). **The new [`runbooks/orphaned-sg-rule.md`](runbooks/orphaned-sg-rule.md)
> prescribes the stamping convention the ingest workflow must implement** — rule description
> `ci-ingest-ephemeral run=<run_id>` + tags `ManagedBy`/`RunId`/`CreatedAt`; orphan detection keys
> off that stamp, so build the workflow to match. Note `terraform plan` **cannot** see an orphaned
> rule (ingress is discrete `aws_vpc_security_group_ingress_rule` resources, not inline blocks) —
> a clean plan is not proof of cleanup. Carry-forward (ADR-0019, lands with the first Lambda/dlt
> read path): create the SSM `SecureString` param + grant `ssm:GetParameter`+`kms:Decrypt`, seed it
> from 1Password, and migrate the lake-RW grant off `tf-apply` onto a dedicated runtime exec role.
>
> **Live infra reference:** lake `pitch-control-lake-749614773761`; RDS
> `pitch-control-pg.c0lwc826eflz.us-east-1.rds.amazonaws.com:5432` / db `pitchcontrol` / user
> `pitchadmin` (password `op://pitch-control/rds-master/password`); connect `verify-full` + RDS CA
> bundle (`infra/README.md` → Connecting). SG is IP-locked — if your IP rotates, re-run the
> `allowed_cidrs` export + `terraform apply` (README "My IP changed"). **Teardown** when done for
> a while (stops credit drawdown): `terraform destroy` (deletion_protection off, skip_final_snapshot
> on — clean). **Free-plan hard stop: `2026-12-11`** — plan the exit by ~Nov 2026 (see *Current
> phase*). B6 (remote state) is pulled forward to now; CI action bumps done 2026-07-16.
>
> <details><summary>Prior next-actions (pre-apply, 2026-07-11) — history</summary>
>
> ⏭️ **NEXT SESSION STARTS HERE (clean boundary):** the Wk 1 skeleton (`339aa63`) and the
> **2026-07-04 pre-apply bundle (`f105681`) are committed + pushed** to `main`. Bundle =
> B2/B3/B4/B7/B8 implemented in Terraform, B9 newly queued
> (second/gross-drawdown budget, not yet written), and A1 resolved as **ADR-0021 ✅ Accepted
> (ratified 2026-07-04)**. Decision log: **0001–0021 ✅ Accepted**. The next move is to
> **stand the infra up**. Resume by: (0) **housekeeping** — store the RDS master password in
> 1Password at `op://pitch-control/rds-master/password` (the path the infra docs now reference);
> (1) **pre-flight — three cheap CLI checks (full block in `infra/README.md`):**
> (a) `aws ec2 describe-vpcs --filters Name=isDefault,Values=true` — `network.tf` **requires a default
> VPC**; empty output = hard failure at plan time (`aws ec2 create-default-vpc` to fix);
> (b) `aws iam list-open-id-connect-providers` — AWS allows only **one** GitHub OIDC provider per
> account, so if one already exists, `apply` collides (switch to a `data` source + import);
> (c) ~~account age~~ **RESOLVED (A2, 2026-07-03)** — account is on the **post-July-2025 credits
> plan** (not the 12-month tier), so there is **no 750-hr RDS allowance**: this apply draws down
> credits at ~**$12–14/mo** (~$75–85 over the plan's 6 months, inside the $100–$200 of credits).
> **$0 out of pocket for ~6 months, then real money.** No age check to run; optionally eyeball
> remaining credits + expiry in Billing console. Follow-up (non-blocking): plan the month-6 exit;
> (2) **set inputs** — `export TF_VAR_db_password=$(op read "op://pitch-control/rds-master/password")`,
> `allowed_cidrs` to current IP (`curl -s https://checkip.amazonaws.com`), and the now-required
> `TF_VAR_budget_notification_email` (no default — kept off-repo; B2); (3) `terraform init` →
> `plan` → `apply` (**creates real billable free-tier AWS resources** — Stephen runs this himself).
> Confirmed at review (no longer open): AWS provider `~> 5.0` and `pg_version = "16"` (major-only) — both
> deliberate; RDS storage switched **gp3 → gp2** (documented free-tier type); S3 lifecycle now
> `depends_on` versioning. **TLS: enforced by default — do NOT add a parameter group for it.** pg16's
> default group ships `rds.force_ssl = 1`, so the instance rejects non-TLS connections out of the box;
> connect with **`sslmode=verify-full`** + the RDS CA bundle
> (`curl -sO https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem`) — encrypt *and* verify
> the server cert (matters given public-RDS + IP-locked SG). psql/Postico setup in `infra/README.md` →
> "Connecting (TLS)". NB: `terraform` **v1.15.6 installed** ✅; `op` (1Password CLI) needed for step 2; `gh` still
> not installed (SSH used for git, optional). Deliberate Wk-1 deviations, documented in `infra/README.md`
> + `backend.tf`: **local state** (not S3 per ADR-0009 → reconcile Wk 5) and **no Lambda
> reserved-concurrency** yet (no Lambdas in Wk 1; ADR-0002 amendment caps land with the API/dlt).
> NB: the plan now also stands up the **2026-07-04 pre-apply bundle** (B2 Budgets alarm, B3 `tf-plan`/
> `tf-apply` split, B4 lake TLS-deny policy) — expect those extra resources on first `plan`.
> Carry-forward to Wk 2: the OIDC `sub` tightening is **now done** for `tf-apply` (B3, `StringEquals` on
> `main`) — remaining is to create the SSM `SecureString` param + grant the Lambda role
> `ssm:GetParameter`+`kms:Decrypt` + the 1Password→SSM seed step (ADR-0019), and migrate the lake-RW grant
> off `tf-apply` onto the dedicated runtime exec role. Stephen runs all git/repo + apply actions himself
> (give commands, don't execute).
>
> **Also pending (repo strategy, 2026-07-04):** **ADR-0022 ✅ ratified 2026-07-04.** Two Stephen-run
> leakage-gate toggles from **B10** remain — `pipx install pre-commit && pre-commit install`
> (activates the `.pre-commit-config.yaml` local gate) and enable **secret scanning + push protection**
> in repo Settings → Code security & analysis. The gate must be live **before Wk 2** (first sensitive
> commit). The Jekyll Pages showcase is a Wk-5+ item, not now.
>
> *(Both B10 toggles were completed 2026-07-11; AWS auth + `op` sign-in + apply all done 2026-07-14.)*
>
> </details>

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

- [x] **Wk 1** — Repo + Terraform skeleton (RDS Postgres, S3 medallion, IAM/OIDC); seed schema. **Infra applied + verified 2026-07-14.** PostHog SDK is app-layer (arrives with the Wk-2+ app), still TODO.
- [ ] **Wk 2** — Bronze: `dlt` jobs (Postgres→S3, FPL→S3) on a GitHub Actions schedule.
- [ ] **Wk 3** — Silver/Gold with dbt-duckdb; tests + lineage; `ops.pipeline_runs`.
- [ ] **Wk 4** — Metabase dashboards on Gold + the manager-360 identity-stitching mart.
- [ ] **Wk 5+** — CI/CD polish (OIDC deploys), elementary observability, error-budget in practice, CDP cohort experiment.

## Session ritual

1. **Start:** read this file + `docs/adr/README.md`; check memory (auto-loaded).
2. **End:** update *Current phase*, *Immediate next actions*, and the date here. Then state whether
   we're at a **clean boundary** (→ start fresh next time) or **mid-decision** (→ `--resume`).

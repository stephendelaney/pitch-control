# ADR-0021: Wk-2 ingest network path — how the Postgres→S3 dlt job reaches RDS

- **Status:** ✅ Accepted (ratified 2026-07-04)
- **Date:** 2026-07-04
- **Deciders:** Stephen Delaney
- **Tags:** data-platform, infra, networking, security, ci-cd

## Context

The Wk-2 dlt job (ADR-0010) reads Postgres and lands Bronze in S3. As built, **it cannot
connect**: OIDC (ADR-0009/0020) grants **IAM credentials, not network reach**. RDS is public but
IP-locked — the SG (`network.tf`) allows 5432 only from `allowed_cidrs` (Stephen's home /32) —
and GitHub-hosted runner IPs are **dynamic** (huge, churning Azure ranges; allowlisting them is
equivalent to public). This is backlog **A1** and blocks Wk 2.

Forces: **cost posture** (credits-plan; no paid escalations — NAT, interface endpoints — without
a decision, `infra/README.md`); **secrets** (ADR-0019: 1Password → SSM `SecureString`, read at
runtime; no secrets in state/env-var config); **IAM** (ADR-0020: one role per compute identity,
runtime ≠ deploy); **TLS** is enforced regardless of path (pg16 `rds.force_ssl=1`, clients
`verify-full`). Related: the ADR-0002 amendment already designs Lambda→RDS connection management
for this read path, and ADR-0007 names Lambda the worker for "VPC access to RDS" — so an in-VPC
Lambda is where the architecture eventually lands; the question is whether Wk 2 is the moment to
pay that path's costs.

## Decision

For Wk 2, the workflow **opens and closes the
SG ingress itself**: a first step authorizes the runner's current IP as a /32 on 5432, dlt runs
**on the GitHub-hosted runner**, and an `if: always()` step revokes the rule; a start-of-run
sweep + scheduled janitor catch orphans. The grant/revoke permission is a narrow policy
(`ec2:AuthorizeSecurityGroupIngress`/`RevokeSecurityGroupIngress`/`DescribeSecurityGroup*`,
resource-scoped to the RDS SG) on the **runtime ingest role** (ADR-0020 — not `tf-apply`).
Revisit when the ADR-0015 API Lambdas land in-VPC (see Consequences).

## Options considered

| Option | Pros | Cons |
|---|---|---|
| **A (chosen): workflow opens/closes SG** (runner IP /32 → run → revoke) | **$0, no new infra**; dlt stays on the runner — no Lambda 15-min cliff for backfills (ADR-0007 amendment); ADR-0019 secret path unchanged (runner reads SSM over the internet via OIDC); bounded exposure: one /32, 5432 only, TLS `verify-full` still enforced, minutes-long | Ugly (mutating security config in a data job); **cleanup failure mode** — a crashed runner can orphan the rule (mitigated: `always()` revoke + start-of-run sweep + scheduled janitor); needs SG-write IAM in CI, however narrow |
| B: Lambda in the default VPC (the ADR-0007 end-state) | Architecturally where RDS-touching compute lands anyway (ADR-0002 amendment); SG-to-SG ingress — no public path, no IP games; free **S3 gateway endpoint** covers the Bronze write | **In-VPC Lambda has no route to SSM without a paid interface endpoint (~$7.3/mo/AZ) or NAT** — breaks ADR-0019's runtime-fetch unless we pay, pass the secret in the invoke payload (fragile: one accidental event-log leaks it), or bake it into config (violates ADR-0019); 15-min cap threatens season backfills; most moving parts to build in Wk 2 |
| C: self-hosted runner | Static IP, trivial allowlist | Standing infra + patching on a personal machine; conflicts with the automation story and the no-always-on posture (ADR-0007). Rejected |
| D: NAT / paid endpoints now | "Correct" enterprise shape | Pure paid escalation for one weekly batch job; explicitly against the credits-plan posture. Rejected |

## Consequences

- **Positive:** Wk 2 unblocked at $0 with no new standing infra. The security model stays
  coherent: the DB is never open to more than one ephemeral /32 beyond home, and TLS +
  `verify-full` hold on every path. IAM stays ADR-0020-clean — SG mutation lives on the runtime
  identity, not the deploy roles.
- **Negative / tradeoffs:** We accept a security-config-mutating data job and own its cleanup
  failure mode (orphaned rule = a /32 with 5432 exposure until the janitor sweeps — bounded, but
  real). The runner→RDS path traverses the public internet (encrypted, IP-pinned, short-lived).
  This is a **bridge, not the end-state**.
- **Follow-ups:** (1) Runbook: `runbooks/orphaned-sg-rule.md` — detect + revoke by rule
  description tag. (2) The ADR-0015 API Lambdas will sit in-VPC and re-open the
  **SSM-interface-endpoint cost question for real**; when that lands, decide it there and migrate
  this job to option B (in-VPC, SG-to-SG) in the same stroke — one decision, one bill, two
  consumers. (3) `infra/variables.tf` `allowed_cidrs` comment + `infra/README.md` A1 note update
  when this is ratified. (4) The ingest role joins the shared runtime exec role per ADR-0020
  (split on divergence).

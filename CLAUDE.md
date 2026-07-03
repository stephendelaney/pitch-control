# CLAUDE.md — operating guide for this repo

House rules for any agent or contributor working in **pitch-control** (local folder: `just-for-fun`).
These are the stable conventions; **live state — "where are we, what's next" — lives in
[`docs/STATUS.md`](docs/STATUS.md), which is the source of truth.**

## What this is

A multi-week, single-maintainer **football-manager / fantasy-GM data platform** — built to
practice real engineering: **Medallion lake** (S3 Parquet Bronze/Silver/Gold) + a **CDP** (PostHog),
with the **identity-stitching** mart as the centerpiece. OLTP system of record is **RDS Postgres +
JSONB**. Stack is deliberately free tooling: DuckDB, dbt-duckdb, dlt, GitHub Actions + Lambda,
Terraform (OIDC), Metabase (local Docker). Primary data source: the free **FPL API**. Full picture:
[`docs/architecture/system-architecture.md`](docs/architecture/system-architecture.md) and
[`docs/product/game-design.md`](docs/product/game-design.md).

## Start-of-session ritual

1. Read [`docs/STATUS.md`](docs/STATUS.md) (current phase + immediate next actions) and
   [`docs/adr/README.md`](docs/adr/README.md) (decision index).
2. Then act. Don't re-derive conventions that are written here.

## End-of-session ritual

Update `docs/STATUS.md` — *Current phase*, *Immediate next actions*, the date — and state whether
we're at a **clean boundary** (start fresh next session) or **mid-decision** (`--resume`).

## Conventions (non-negotiable unless changed here)

- **`docs/STATUS.md` is the single source of truth** for progress. Keep it current; don't scatter
  state into other files.
- **ADR flow.** Significant decisions are recorded as [MADR-lite](docs/adr/template.md) ADRs.
  New decisions are drafted as **📝 Proposed** (rationale written, awaiting sign-off); **the
  maintainer ratifies** to **✅ Accepted**. Accepted ADRs are **immutable — supersede or amend,
  never rewrite.** Copy `docs/adr/template.md` to the next number.
- **The maintainer runs all git, `terraform apply`, and repo/GitHub actions himself.** Provide the
  exact command(s) and the *why* — do **not** execute them. This includes commits, pushes, PRs, and
  anything that creates billable AWS resources.
- **Cost posture.** The AWS account is on the **post-July-2025 credits plan**, *not* the 12-month
  free tier — so spend is **credit-funded (~6 months), not $0-structural**. Keep the config minimal
  (free-tier-class instances, no paid escalations — RDS Proxy, Secrets Manager, KMS, NAT — without a
  decision). Plan the **month-6 exit** before credits lapse. Details:
  [`infra/README.md`](infra/README.md).
- **Secrets never touch disk.** 1Password is the source of truth; inject at runtime via the `op`
  CLI; Lambdas read from SSM `SecureString` seeded from 1Password (ADR-0019). No secret values in
  committed files or example URIs.
- **RDS TLS is enforced by default.** pg16's default parameter group ships `rds.force_ssl = 1` —
  the instance rejects non-TLS connections out of the box. **Do not add a parameter group to "turn
  on" SSL.** Clients connect with **`sslmode=verify-full`** + the RDS CA bundle.
- **IAM = one role per compute identity, least privilege** (ADR-0020): `tf-plan` (read-only, any
  ref) / `tf-apply` (write, pinned to `main`); shared runtime exec role, split on divergence.

## Repo map

| Path | What |
|---|---|
| `docs/STATUS.md` | **Live state** — read first, update last |
| `docs/adr/` | Decision records ([index](docs/adr/README.md)) + MADR-lite template |
| `docs/backlog.md` | Assessed improvements queue (decisions + delegable tasks) |
| `docs/architecture/` | C4 diagrams (Mermaid) |
| `docs/product/game-design.md` | Game mechanics + the data they generate |
| `docs/slo/`, `docs/runbooks/`, `docs/retros/` | SRE-for-data rigor |
| `infra/` | Terraform (RDS, S3 lake, IAM/OIDC) — see `infra/README.md` |

> Personal context about the maintainer (background, preferences) lives in private session memory,
> not here — this file is the public, repo-scoped subset by design.

# ADR-0002: PostgreSQL + JSONB for the system of record

- **Status:** Accepted
- **Date:** 2026-06-13
- **Deciders:** Stephen Delaney
- **Tags:** data-platform, infra, database

## Context

The platform needs an OLTP system of record for transactional, "core business" data: user-managed
squads, transfers (buy/sell, fees, budgets), lineups, and gameweek scores, plus ingested reference
data (players, teams, prices). Some source payloads (raw FPL API responses) are semi-structured and
are best landed as documents before they are flattened. Constraints: must run on the AWS RDS free
tier; maintainer is solo; cost must stay $0.

The maintainer is **more familiar with PostgreSQL** (uses the Postico client) and was mildly open to
learning MySQL, but not at the expense of the best architectural fit. Note: `JSONB` is a PostgreSQL
type — MySQL offers a `JSON` type with weaker indexing and operators.

## Decision

We will use **PostgreSQL** on RDS (`db.t4g.micro`, free tier) as the system of record, using `JSONB`
columns for semi-structured landing data and relational tables for modeled transactional entities.

## Options considered

| Option | Pros | Cons |
|---|---|---|
| **Postgres + JSONB (chosen)** | True `JSONB` w/ GIN indexes + rich operators; ideal for event/CDP-style payloads; first-class dbt/DuckDB support; **maintainer's stronger / more-familiar engine** (Postico licensed) | Forgoes MySQL, a minor stated learning interest |
| MySQL + JSON | A learning opportunity for the maintainer | Binary `JSON` only — no `JSONB` operators/indexing; weaker fit for document-heavy landing |

## Consequences

- **Positive:** Strong semi-structured support for Bronze landing; GIN-indexable JSONB for CDP
  payloads; clean path into the DuckDB/dbt warehouse; Postico connects directly to RDS.
- **Tradeoffs:** We forgo MySQL, which the maintainer was mildly interested in learning. Accepted
  because Postgres is both the stronger architectural fit *and* the more-familiar engine — low risk.
- **Follow-ups:** ADR-0013 (identity stitching) depends on this; schema lives in `infra/` (Terraform)
  and `app/` migrations.

## Amendment — 2026-06-29 (Accepted)

> Status: **✅ Accepted** (ratified 2026-06-30). Adds an operational guardrail; does not change the
> chosen engine.

**Lambda→Postgres connection management.** Both the API (ADR-0015) and the dlt-from-Postgres read path
(ADR-0010) reach RDS from **Lambda**, which scales horizontally by default — each concurrent function
opens its own connection. Against a free-tier **`db.t4g.micro`** with a low `max_connections`, an
unbounded fan-out causes **connection exhaustion / storms** (failed connects, not slow queries). This
is a known Lambda+RDS footgun and is called out here so it's designed in, not discovered in an
incident.

Mitigation, **$0-first**:

1. **Cap the fan-out.** Set **reserved concurrency** on the RDS-touching Lambdas to a small number so
   peak connections stay well under `max_connections`. (Free.)
2. **Reuse the connection.** Open the pool/connection **outside the handler** (in the execution
   context) so warm invocations reuse it; keep pools tiny (1–2); set short idle timeouts. (Free.)
3. **Escalation — RDS Proxy.** The managed answer (pooling/multiplexing in front of RDS) is **RDS
   Proxy**, but it is **not free** (≈ $0.015/vCPU-hr), so it **violates the $0 constraint** and is
   deferred. Adopt it only if (1)+(2) prove insufficient or when budget allows — it's the documented
   escalation, not the default.

Related: ADR-0007 amendment (2026-06-29), ADR-0010 (dlt), ADR-0015 (API Lambda).

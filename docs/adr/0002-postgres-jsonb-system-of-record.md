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

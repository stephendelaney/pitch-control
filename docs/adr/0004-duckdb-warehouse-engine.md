# ADR-0004: DuckDB as the warehouse query engine

- **Status:** Accepted
- **Date:** 2026-06-14
- **Deciders:** Stephen Delaney
- **Tags:** data-platform, engine, warehouse

## Context

The S3 + Parquet lake (ADR-0003) needs a **query/compute engine** to run the Silver/Gold transforms
(ADR-0005) and to serve marts to BI (ADR-0008). We need something that reads Parquet directly from
S3, runs analytical SQL fast, costs **$0**, and has **first-class dbt support** so the transform
layer is portable. This is the compute half of the coupled storage+compute bet made in ADR-0003.

Constraints: free tier / no standing compute; solo maintainer; data is MB-to-low-GB scale, which
fits comfortably **in-process on a single node** — we do not need distributed compute.

## Decision

We will use **DuckDB** as the warehouse engine, run **in-process** (inside dbt-duckdb jobs and ad-hoc
sessions), reading Parquet directly from S3 via its `httpfs`/`parquet` extensions. There is **no
always-on warehouse**; compute is ephemeral, spun up per job in GitHub Actions / Lambda (ADR-0007).

## Options considered

| Option | Pros | Cons |
|---|---|---|
| **DuckDB (chosen)** | $0, zero infra (embedded, no server); reads S3 Parquet natively; excellent analytical SQL; first-class `dbt-duckdb`; runs identically on laptop + CI; perfect for single-node MB–GB scale | Single-node only (irrelevant at this scale); no shared persistent service — each job is cold; concurrency is per-process |
| Amazon Athena | Serverless, no infra; reads S3 directly | Per-query cost ($5/TB) — not durably $0; weaker dbt ergonomics; slower iteration loop than embedded DuckDB |
| Amazon Redshift / Serverless | Powerful MPP warehouse | Costs money (no durable free tier); massively over-scaled for MB–GB; heavy ops for a solo project |
| Postgres-as-warehouse | Already in the stack (ADR-0002) | Row store — poor columnar scan performance; couples analytics load to the OLTP free-tier instance |

## Consequences

- **Positive:** Truly $0 and zero standing infra — compute exists only while a job runs. Same engine
  on laptop and in CI means **dev/prod parity** and a tight local iteration loop. Native Parquet+S3
  reads make ADR-0003's lake immediately queryable. `dbt-duckdb` keeps the transform layer (ADR-0005)
  idiomatic and portable.
- **Negative / tradeoffs:** Single-node ceiling — fine now, but a real scale wall if data grew orders
  of magnitude (not expected for a personal FPL platform). No persistent shared warehouse, so every
  job pays cold-start and there's no concurrent multi-user query service; **Metabase (ADR-0008) will
  query materialized Gold Parquet/marts**, not a live DuckDB server. We accept these as correct for
  the scale and budget.
- **Follow-ups:** ADR-0005 (dbt-duckdb transforms), ADR-0007 (where DuckDB jobs execute), ADR-0008
  (Metabase reads materialized Gold). If single-node scale ever binds, the open Parquet lake means we
  can point Athena/Spark/Trino at the same data without re-storing it — a superseding ADR, not a
  migration.

# ADR-0005: dbt for Silver/Gold transformations

- **Status:** Accepted
- **Date:** 2026-06-19
- **Deciders:** Stephen Delaney
- **Tags:** data-platform, transform, modeling

## Context

The Medallion lake (ADR-0003) lands raw Bronze and needs a **transformation layer** to model Silver
(cleaned/conformed) and Gold (marts) on top of the DuckDB engine (ADR-0004). We need SQL-first
modeling with **dependency-ordered builds, tests, documentation, and lineage** — the centerpiece
identity spine `dim_identity_map` and `mart_manager_360` (ADR-0013) live here, and the
identity-resolution-rate correctness SLI (ADR-0012) is enforced as a model test.

Constraints: $0 / no standing infra; solo maintainer; transforms run inside the GitHub Actions +
Lambda orchestration (ADR-0007); the engine is in-process DuckDB, so the transform tool must adapt
cleanly to it. Learning goal: practice analytics-engineering discipline (refs, tests, exposures,
docs) deliberately, not just produce tables.

## Decision

We will use **dbt** (open-source dbt-core) with the **`dbt-duckdb`** adapter to build Silver and Gold
as version-controlled, tested SQL models reading from and writing to the S3 Parquet lake. Bronze
stays source-faithful (ADR-0003); **all** business logic, conforming, and identity stitching lives in
dbt models with `schema.yml` tests and generated docs/lineage.

## Options considered

| Option | Pros | Cons |
|---|---|---|
| **dbt-core + dbt-duckdb (chosen)** | $0, OSS; first-class DuckDB adapter (ADR-0004); refs/DAG/tests/docs/exposures out of the box; same run on laptop + CI; the industry-standard analytics-engineering practice surface we want to learn; lineage doc site for free | Another tool + Jinja/SQL templating to learn; macros can get clever; orchestration of dbt runs is still on Actions (ADR-0007) |
| Hand-written SQL scripts + a runner | No framework to learn; total control | Re-invents refs/tests/docs/lineage by hand; brittle ordering; no standard test surface for the ADR-0012 SLI; throws away the main learning goal |
| SQLMesh | Modern: virtual envs, column-level lineage, stronger incremental semantics | Smaller ecosystem/community; less ubiquitous as a résumé/learning skill; DuckDB support good but dbt is the conventional reference point we want |
| Spark/PySpark transforms | Powerful, scalable | Over-scaled for MB–GB single-node (ADR-0004); heavier infra; not $0-friendly; abandons the SQL-first modeling practice |

## Consequences

- **Positive:** Silver/Gold become a tested, documented, lineage-visible DAG. `dim_identity_map` and
  the marts (ADR-0013) get a natural home with first-class tests, including the resolution-rate SLI
  (ADR-0012). `dbt-duckdb` means dev/prod parity with the engine (ADR-0004); `dbt build` is a single
  orchestrated step in Actions (ADR-0007). Generated docs are a free lineage artifact for the C4
  learning track.
- **Negative / tradeoffs:** Jinja/macro complexity is a real footgun; we keep models flat and
  readable and lean on `ref()`/tests over cleverness. dbt orders the model DAG but **does not
  schedule** — that stays with Actions. State/incremental ergonomics on an object-store lake are
  more manual than on a warehouse; we default to full-rebuild/partition-overwrite (ADR-0003) and add
  incrementals only where they pay off.
- **Follow-ups:** ADR-0004 (engine), ADR-0003 (lake I/O), ADR-0007 (where `dbt build` runs),
  ADR-0013 (owns `dim_identity_map` + resolution test), ADR-0012 (registers the correctness SLI),
  ADR-0008 (Metabase reads dbt-materialized Gold). elementary on top of dbt artifacts is a roadmap
  Wk 3 observability item.

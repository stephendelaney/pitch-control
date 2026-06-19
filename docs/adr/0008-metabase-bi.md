# ADR-0008: Metabase (local Docker) for BI

- **Status:** Accepted
- **Date:** 2026-06-19
- **Deciders:** Stephen Delaney
- **Tags:** data-platform, bi, visualization

## Context

The Gold marts (ADR-0005) — `mart_manager_360`, `mart_engagement_vs_performance` (ADR-0013) — need a
**BI / visualization** layer to turn the headline analytical question into dashboards. We need
SQL-friendly exploration and dashboards over the materialized Gold layer at **$0**, with **no
always-on hosted cost**. The engine (ADR-0004) is in-process DuckDB with no persistent server, so BI
must read **materialized Gold Parquet/marts**, not a live warehouse connection (a constraint already
called out in ADR-0004).

Constraints: $0; solo maintainer; data is MB–GB; this is a personal platform, so a locally-run BI
tool (spin up when exploring, shut down otherwise) is perfectly acceptable — we do not need an
always-on shared dashboard service.

## Decision

We will run **Metabase locally via Docker**, pointed at the **materialized Gold** marts. Concretely,
Gold is published to a queryable target Metabase supports — a **DuckDB file / Postgres marts schema**
loaded from Gold Parquet — so Metabase reads stable materialized tables, not an ephemeral in-process
DuckDB job. Metabase runs **on demand** on the laptop; there is no hosted BI service.

## Options considered

| Option | Pros | Cons |
|---|---|---|
| **Metabase, local Docker (chosen)** | $0, OSS; excellent self-serve + SQL dashboards; trivial `docker run`; reads Postgres/DuckDB marts; great learning surface; no hosted cost | Local-only (no shared URL) unless we later host it; must point at *materialized* Gold, not live DuckDB (ADR-0004); manage one container |
| Metabase hosted (Metabase Cloud) | Managed, shareable URL | Paid — fails the $0 constraint |
| Apache Superset (local) | OSS, powerful, rich viz | Heavier setup/footprint than Metabase; steeper for a solo on-demand use; more ops for little gain at this scale |
| Streamlit / custom app | Full control, code-first | Re-invents dashboards; more build time; weaker ad-hoc exploration than a real BI tool |
| Notebook (DuckDB + plotting) | Zero infra; already have the engine | No dashboard/share surface; not the BI-tool learning goal; ad-hoc only |

## Consequences

- **Positive:** A real BI surface over Gold at $0, spun up only when needed. Reading materialized Gold
  respects the no-persistent-warehouse design (ADR-0004) and gives stable, fast dashboards. Good
  hands-on BI learning; the manager-360 identity-stitching mart gets a visible payoff (roadmap Wk 4).
- **Negative / tradeoffs:** Local-only means no always-on shared link — acceptable for a personal
  project; hosting Metabase later (e.g. on a small instance) would be a follow-up ADR, not a
  migration. We **must materialize Gold** to a Metabase-friendly store rather than query the ephemeral
  DuckDB jobs directly — a small publish step in the pipeline (ADR-0007). Dashboards are only as fresh
  as the last Gold build; freshness is an SLI (ADR-0012).
- **Follow-ups:** ADR-0004 (why BI reads materialized Gold), ADR-0005 (marts Metabase consumes),
  ADR-0013 (the manager-360 mart this visualizes), ADR-0007 (publish-Gold step), ADR-0009 (if we ever
  host Metabase, Terraform provisions it). Roadmap Wk 4 builds the first dashboards.

# ADR-0010: dlt for Bronze ingestion

- **Status:** Accepted
- **Date:** 2026-06-19
- **Deciders:** Stephen Delaney
- **Tags:** data-platform, ingestion, bronze, extract-load

## Context

Bronze (ADR-0003) is fed from several sources that must be **extracted and loaded source-faithfully**
into S3: the FPL API (ADR-0011, semi-structured JSON), the OLTP Postgres SoR (ADR-0002), and exported
PostHog events (ADR-0006). We need a lightweight **EL (extract-load)** tool that handles pagination,
incremental loading, schema inference, and idempotent writes to S3 — runnable inside GitHub Actions +
Lambda (ADR-0007) at **$0**, with **no business logic at ingest** (Bronze stays raw, ADR-0003).

Constraints: $0 / no standing infra; solo maintainer; Python-based to fit the Lambda/Actions runtime;
must write Parquet/JSON to S3 and track incremental state cheaply.

## Decision

We will use **dlt** (data load tool, OSS Python) for Bronze ingestion: one pipeline per source
(FPL → S3, Postgres → S3, PostHog → S3), configured with **filesystem/S3 destination**, dlt's
**incremental** + schema-inference primitives, and **append-only / replayable** Bronze writes
(ADR-0003). dlt does **EL only** — no transforms; all modeling is dbt downstream (ADR-0005). Pipelines
are invoked by the orchestrator (ADR-0007).

## Options considered

| Option | Pros | Cons |
|---|---|---|
| **dlt (chosen)** | $0, OSS, pip-installable (fits Lambda/Actions); built-in pagination, incremental, schema inference/evolution, retries; S3/filesystem destination writes Parquet; Pythonic, low-ceremony; pairs naturally with dbt (EL + T split) | Younger than the alternatives; some sources need custom resource code; state/incremental semantics to learn |
| Airbyte (OSS/Cloud) | Huge connector catalog, UI | Wants standing infra/containers (self-host) or paid cloud — **not $0**; heavy for 3 simple sources |
| Meltano / Singer taps | Mature spec, many taps | More config ceremony; tap/target quality varies; heavier than dlt for this handful of sources |
| Hand-rolled Python (requests + boto3) | Total control, zero deps | Re-invents pagination/incremental/schema/retries; more brittle code to own; throws away the EL learning surface |
| Fivetran / Stitch (managed) | Zero-ops connectors | Paid beyond tiny free tiers; vendor-bound; not a $0, hands-on learning fit |

## Consequences

- **Positive:** Source-faithful Bronze loads with pagination/incremental/schema handled by the tool,
  not by us. Pure Python fits the Lambda + Actions runtime (ADR-0007) and stays $0. Clean **EL/T
  separation** with dbt (ADR-0005). Realistic ingestion-engineering learning surface (roadmap Wk 2).
- **Negative / tradeoffs:** dlt is a newer tool — some sources (PostHog export, FPL endpoints) need
  custom resource code and tuning of incremental cursors. We own that code and keep it thin. Schema
  evolution from FPL's loosely-typed JSON needs care; Bronze tolerates it by staying raw (ADR-0003)
  and pushing typing to Silver (ADR-0005).
- **Follow-ups:** ADR-0003 (Bronze write target/format), ADR-0011 (FPL source specifics), ADR-0002
  (Postgres source), ADR-0006 (PostHog export source), ADR-0007 (where pipelines run), ADR-0012
  (per-source ingest-freshness/pipeline-success SLIs). Runbook:
  [`runbooks/bronze-load-failure.md`](../runbooks/bronze-load-failure.md). Roadmap Wk 2 builds the
  first dlt jobs.

# ADR-0003: S3 + Parquet Medallion lake (Bronze/Silver/Gold)

- **Status:** Accepted
- **Date:** 2026-06-14
- **Deciders:** Stephen Delaney
- **Tags:** data-platform, infra, lake, storage

## Context

Beyond the OLTP system of record (ADR-0002), the platform needs an analytics **lake** to land raw
source data, refine it, and serve modeled marts — without coupling analytics scans to the
transactional database. We want to practice **Medallion architecture** (Bronze → Silver → Gold) as a
first-class learning goal, and to keep the analytics path cheap, durable, and engine-agnostic.

Forces and constraints:
- **Cost = $0.** AWS S3 standard storage is effectively free at this data volume (FPL + a few CSV
  sources is megabytes-to-low-gigabytes); S3 has no idle/compute cost, unlike a running warehouse.
- **Solo maintainer**, so operational surface must stay near zero — no clusters to babysit.
- The query engine (ADR-0004) and transforms (ADR-0005) read from this lake, so the storage format
  must be **open and columnar** — not locked to one vendor's engine.
- Source payloads are semi-structured JSON (FPL API) plus tabular CSV (Transfermarkt/Kaggle).

## Decision

We will use **Amazon S3 as the data lake**, organized into **Bronze / Silver / Gold** prefixes, with
**Apache Parquet** as the storage format for Silver and Gold (Bronze keeps raw payloads in their
native form — JSON/CSV — for replayability). Layout: `s3://<bucket>/{bronze,silver,gold}/<source>/…`,
partitioned by ingestion/event date where it aids pruning.

## Options considered

| Option | Pros | Cons |
|---|---|---|
| **S3 + Parquet, Medallion (chosen)** | $0 at rest; open columnar format read by every engine (DuckDB, Athena, Spark); durable (11 9s); no compute to idle; clean Medallion teaching surface; engine-swappable later | Object store, not a DB — no ACID/transactions without a table format; small-file management is on us |
| S3 + Iceberg/Delta table format | ACID, schema evolution, time-travel, compaction | Heavier setup; DuckDB Iceberg support still maturing; over-engineered for MB-scale solo project — adds learning cost without payoff *yet* |
| Keep everything in Postgres (no lake) | One system; simplest | Couples analytical scans to the OLTP free-tier instance; no Medallion practice; columnar scans on row store are slow; misses an explicit project goal |
| BigQuery / Snowflake free tier | Managed, powerful | Vendor lock-in; free tiers are time/credit-limited (not durably $0); buries the storage-vs-engine separation we want to learn |

## Consequences

- **Positive:** Storage and compute are decoupled — the lake outlives any engine choice. Parquet +
  partitioning gives fast, cheap columnar scans. Bronze-keeps-raw means every downstream layer is
  **reproducible from source** (replay = re-run Silver/Gold). Naturally exercises Medallion.
- **Negative / tradeoffs:** No table-format ACID guarantees — concurrent writers and in-place updates
  are not safe; we mitigate by treating Bronze as append-only and Silver/Gold as
  **full-rebuild-or-partition-overwrite** (idempotent), which suits batch. We accept manual
  small-file hygiene. Revisiting Iceberg is a deliberate later upgrade, not a day-1 need.
- **Follow-ups:** ADR-0004 (DuckDB reads this lake), ADR-0005 (dbt writes Silver/Gold), ADR-0010
  (dlt lands Bronze), ADR-0009 (Terraform provisions the bucket + lifecycle rules). Runbook:
  [`runbooks/bronze-load-failure.md`](../runbooks/bronze-load-failure.md). If write concurrency or
  in-place upserts become real needs, open a superseding ADR for Iceberg/Delta.

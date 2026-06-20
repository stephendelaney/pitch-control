# pitch-control

> A soccer-manager data platform — Medallion lake + CDP + identity stitching, with an ADR behind every decision.

A personal **football-manager / fantasy-GM data platform** — buy/sell players, set lineups, track
gameweek performance — built as a vehicle for practicing production data-engineering and SRE
discipline on **strictly free tooling**.

The fun surface is the game. The point is the engineering rigor underneath it: a **Medallion data
lake**, a **Customer Data Platform**, identity stitching across them, and the full DevOps quartet
(IaC, CI/CD, SRE, decision logs) treated as first-class deliverables.

## Two data domains

- **Business / OLTP** — RDS Postgres (+ JSONB): squads, transfers, budgets, lineups, gameweek
  scores, plus ingested players/teams/prices. The system of record.
- **Engagement / CDP** — PostHog Cloud: user events, person profiles, league groups, cohorts.

Gold marts join the two on `user_id ↔ PostHog distinct_id` — **identity stitching is the
centerpiece** (see [ADR-0013](docs/adr/0013-identity-stitching.md)).

## Stack (all free tier)

S3 Parquet Medallion (Bronze/Silver/Gold) · DuckDB warehouse engine · dbt-duckdb transforms ·
dlt ingestion · RDS Postgres · GitHub Actions + Lambda orchestration · Terraform IaC (OIDC, no
static keys) · Metabase BI · PostHog product analytics/CDP. Primary source: the free
[Fantasy Premier League API](https://fantasy.premierleague.com/api/).

**Experience/app layer:** React SPA on S3 + CloudFront · API Gateway + Lambda (FastAPI) · Cognito
for auth + canonical user identity.

## Documentation

The [`docs/`](docs/) tree is the project's decision-capture and reliability system. Start with the
[knowledge-base README](docs/README.md) and the [current status](docs/STATUS.md).

| Area | Location |
|---|---|
| Where we are now | [`docs/STATUS.md`](docs/STATUS.md) |
| Architecture (C4 + Mermaid) | [`docs/architecture/`](docs/architecture/system-architecture.md) |
| Decision log (ADRs 0001–0018) | [`docs/adr/`](docs/adr/) |
| Game design & mechanics | [`docs/product/game-design.md`](docs/product/game-design.md) |
| SLOs & error budget | [`docs/slo/`](docs/slo/data-platform-slos.md) |
| Runbooks | [`docs/runbooks/`](docs/runbooks/) |

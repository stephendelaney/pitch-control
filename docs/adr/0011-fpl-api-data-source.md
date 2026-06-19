# ADR-0011: FPL API as the primary external data source

- **Status:** Accepted
- **Date:** 2026-06-19
- **Deciders:** Stephen Delaney
- **Tags:** data-platform, source, fpl, ingestion

## Context

The game's scoring and player universe mirror **Fantasy Premier League** (game-design spec; ADR-0017
ingests FPL `event_points`, ADR-0018 mirrors FPL transfer/economy rules). We need an authoritative,
free external feed for **players, teams, fixtures, live/event points, and prices** to seed the game
and to act as the **oracle** for the Phase-2 compute-and-reconcile scoring engine (ADR-0017).

Constraints: $0; solo maintainer; the source must be reliably fetchable from Lambda/Actions
(ADR-0007) and land source-faithfully in Bronze via dlt (ADR-0010, ADR-0003). The FPL API is a public,
undocumented/unofficial JSON API — no auth, no formal SLA, subject to change.

## Decision

We will use the **public FPL API** (`fantasy.premierleague.com/api/…`) as the primary external data
source: `bootstrap-static` (players/teams/events/prices), `fixtures`, and `event/{gw}/live` (gameweek
points), ingested by dlt (ADR-0010) into Bronze **exactly as returned** (ADR-0003). We treat it as
**unofficial and contract-unstable**: schema-tolerant capture in Bronze, polite low-frequency polling,
and validation in Silver (ADR-0005). It is the scoring **oracle** for ADR-0017.

## Options considered

| Option | Pros | Cons |
|---|---|---|
| **Public FPL API (chosen)** | $0, no auth; exactly the player/scoring universe the game mirrors (ADR-0017/0018); JSON fits dlt + Bronze; rich enough for marts and the compute-and-reconcile oracle; gameweek cadence suits batch | Unofficial/undocumented — no SLA, can change without notice; rate-limit/etiquette unclear; semi-structured loosely-typed JSON needs Silver validation |
| Paid football-data API (e.g. Opta/StatsBomb/API-Football paid tiers) | Documented, SLA, richer stats | Costs money — fails $0; over-scoped; doesn't match the FPL scoring model we mirror |
| Static Kaggle / CSV datasets | Stable, versioned, offline | Stale (no live gameweek points); no ongoing feed; can't drive a live-ish game loop |
| Scrape Premier League / club sites | Free, detailed | Fragile HTML scraping; ToS/legal grey area; far more brittle than the JSON API |

## Consequences

- **Positive:** Free, directly aligned with the FPL-mirrored game (ADR-0017/0018), and structured
  enough for both marts and the Phase-2 reconcile oracle. JSON → dlt → Bronze is a clean fit
  (ADR-0010/0003). Gameweek + daily cadence matches the batch orchestration (ADR-0007).
- **Negative / tradeoffs:** **Unofficial, no SLA** — the schema can shift and break ingestion; we
  defend with schema-tolerant Bronze (ADR-0003), Silver validation/tests (ADR-0005), and a
  freshness/ingest SLI + runbook (ADR-0012). We poll **politely** (low frequency, cached, backoff) to
  respect the unofficial endpoint. If FPL ever blocks or breaks materially, a Kaggle snapshot is the
  documented fallback for non-live data.
- **Follow-ups:** ADR-0010 (dlt FPL pipeline + incremental cursors), ADR-0003 (raw Bronze capture),
  ADR-0017 (FPL as scoring source/oracle), ADR-0018 (FPL transfer/economy rules), ADR-0005 (Silver
  validation), ADR-0012 (FPL ingest-freshness SLI). Runbook:
  [`runbooks/bronze-load-failure.md`](../runbooks/bronze-load-failure.md).

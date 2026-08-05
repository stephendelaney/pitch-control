# ADR-0023: Silver snapshot semantics — the latest committed load, not the latest observation

- **Status:** Accepted
- **Date:** 2026-08-04 (ratified 2026-08-05)
- **Deciders:** Stephen Delaney
- **Tags:** data-platform, transform, modeling, correctness

## Context

Bronze is **append-only** ([ADR-0003](0003-s3-parquet-medallion-lake.md)) and both ingest jobs
write a **full re-snapshot on every run** — the FPL job by design, the Postgres job explicitly
so ([`ingest/README.md`](../../ingest/README.md) → *Full snapshot, not incremental*). After six
runs, a player exists in Bronze six times.

Silver ([ADR-0005](0005-dbt-transformations.md)) has to reduce that to a current-state row per
key, and the reduction rule is not a detail: it decides what "the current squad" *means*, it
applies identically to every staging model now and to the Postgres tables when the app layer
lands, and getting it wrong produces wrong answers rather than errors.

Three forces:

- **Entities disappear upstream.** FPL removes players; a future app will soft-delete rows. A
  reduction rule either notices or it does not.
- **Loads can be partial.** An object store has no transactions (ADR-0003 accepts this
  explicitly). A run killed mid-write — a hard-killed GitHub runner, which
  [ADR-0021](0021-ci-ingest-network-path.md)'s janitor exists precisely because it happens —
  leaves data files behind for some tables and not others.
- **Builds are not instantaneous.** The daily ingest (06:00 UTC) and any transform run are
  separate jobs against a shared lake, so a load can commit while a build is in flight.

The player count has already moved 564 → 567 → 568 across the first six loads, so this is a live
concern in week one, not a theoretical one.

## Decision

Silver models will select **every row from exactly one Bronze load** — the most recent load
whose entry in dlt's `_dlt_loads` ledger has `status = 0` (committed) — rather than reducing to
the latest observation per key.

The load id is resolved by a single macro (`latest_completed_load()`), and a singular test
asserts that all models in a build resolved it to the same committed value.

## Options considered

| Option | Pros | Cons |
|---|---|---|
| **A. Latest committed load, from the `_dlt_loads` ledger (chosen)** | Silver is exactly one internally-consistent snapshot; a removed entity disappears, which is the truth; partial loads are structurally unselectable, since a run that dies never writes its ledger row; the rule is one macro and applies unchanged to the Postgres tables | Depends on a dlt implementation detail (the ledger and its status code); needs a test to catch models disagreeing mid-build; discards the intra-day history that multiple same-day loads represent |
| B. Latest observation per key (`row_number()` over a partition) | The conventional dbt deduplication idiom; tolerant of a partial load, since another load can still supply a key | **An entity removed upstream keeps its last observation forever** — Silver silently accumulates things that no longer exist, and nothing surfaces it; row counts stop meaning anything; a partial load's rows silently mix with an older load's |
| C. Latest `load_date` partition | Cheapest to express; prunes well | Wrong whenever a day has more than one load (2026-08-04 already has three); says nothing about whether the load committed |
| D. Keep all observations; make Silver a history table | Loses nothing; enables price/form time series | Changes Silver's grain from "current state" to "observation", which pushes the same reduction problem onto every Gold model instead of solving it once |

## Consequences

- **Positive:** Silver is a single coherent snapshot, so a join across staging models cannot
  straddle two versions of the world. Disappearances are visible as row-count changes rather
  than silent ghosts. Partial loads are excluded by construction rather than by a heuristic. One
  macro governs every model, including the Postgres ones when they arrive.
- **Negative / tradeoffs:** We take a dependency on dlt's `_dlt_loads` ledger — a tool-specific
  artifact, which is the price of getting commit semantics from a store that has no
  transactions. Because each model resolves the load independently at run time, a load
  committing mid-build could hand different models different snapshots; that race is covered by
  `tests/assert_silver_reads_one_committed_snapshot.sql` rather than prevented, since preventing
  it needs run-scoped state dbt does not offer here. We also accept that **history is not in
  Silver**: multiple loads per day exist in Bronze and are discarded on the way through. That is
  a deliberate deferral, not a loss — Bronze is append-only and retains every observation, so a
  history model (player price and form over time, which the game genuinely wants) can be built
  later from the same source without a re-ingest.
- **Follow-ups:** A Gold-layer decision on price/form history — option D's use case — reading
  Bronze directly rather than Silver. Revisit if a future source stops re-snapshotting in full
  and moves to `dlt.sources.incremental` (the ~100k-row trigger in `ingest/README.md`), because
  under an incremental load "one load" is a delta, not a snapshot, and this rule would no longer
  apply to that table.

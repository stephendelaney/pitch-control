# ADR-0017: Scoring source — ingest FPL points vs compute our own

- **Status:** Accepted
- **Date:** 2026-06-18
- **Deciders:** Stephen Delaney
- **Tags:** data-platform, game-mechanics, correctness, ingestion

## Context

A manager's gameweek score is built from **per-player gameweek points** (see
[`../product/game-design.md`](../product/game-design.md) §4 for the scoring table). There are two
ways to obtain those per-player numbers:

- **(a) Ingest FPL's already-computed points.** The Fantasy Premier League API (ADR-0011) exposes
  `event_points` per player per gameweek — FPL has already applied its own scoring rules to real
  match stats. We ingest that number and treat it as the source of truth.
- **(b) Compute points ourselves** from the raw component stats (minutes, goals, assists, clean
  sheets, saves, cards, BPS-derived bonus…) that the same API also exposes, re-implementing the
  FPL scoring formula in our own transforms.

It is worth being precise about what is — and is not — at stake. This decision is **only about the
source of per-player points.** The *manager-level* score is **ours either way**: captain doubling,
auto-substitution (ADR game-design §3), and transfer penalties (ADR-0018) are our business logic in
dbt regardless of where the raw per-player number comes from. So (a) does not mean "we own no
scoring logic" — it means we don't re-derive the number FPL already publishes.

Forces / constraints:
- **FPL is the primary source (ADR-0011) and it is free.** The points it publishes are, by
  definition, the correct points for *this* game, because our game mirrors FPL conventions.
- **Solo maintainer, $0.** Re-implementing the full FPL scoring formula (especially the BPS bonus
  system, which is genuinely fiddly) is real, ongoing code to write *and keep correct* as FPL tweaks
  rules between seasons.
- **Correctness is a tracked SLI (ADR-0012, ADR-0013).** Option (b) creates a *correctness
  obligation we have to defend*: every divergence between our number and FPL's is a bug we own.
  Option (a) is correct-by-construction and needs no such defence.
- **Learning goal cuts the other way.** Computing points ourselves is a richer engineering surface
  (a real transformation with an exact, free oracle to test against) and is the *only* option if we
  ever deliberately diverge from FPL's rules (e.g. a custom league scoring variant).

## Decision

We will **ingest FPL's per-player `event_points` as the canonical scoring source (option a)** for the
core build, and own only the manager-level aggregation (captain, auto-subs, transfer hits) in dbt.

Two deliberate hedges so this is a starting point, not a dead end:

1. **Ingest the component stats too, not just the total.** Even though we only *use* `event_points`
   now, the Bronze ingestion (ADR-0010 / `dlt`) will also land the underlying per-player stats
   (minutes, goals, assists, clean sheets, saves, cards, bonus, BPS) that FPL exposes in the same
   payload. They cost nothing extra to capture and they keep option (b) unblocked later without a new
   ingestion job.
2. **Keep "compute-our-own-points engine" as a backlogged Phase 2 learning stretch.** When built, it
   runs *in parallel* and reconciles against the ingested `event_points`, which becomes its **test
   oracle** — i.e. a correctness SLI for free. We adopt our own number as canonical only if/when it
   reconciles, and only then would a deliberate rules divergence become possible.

Bronze stays source-faithful (it stores FPL's `event_points` verbatim); the manager-score logic
lives in Silver/Gold dbt models (ADR-0005), consistent with the Medallion split (ADR-0003).

## Options considered

| Option | Pros | Cons |
|---|---|---|
| **(a) Ingest FPL `event_points`, own only manager-level aggregation (chosen)** | Correct-by-construction — zero correctness debt; trivial and free; matches FPL rules exactly because the game *is* FPL-aligned; we still own the genuinely interesting logic (captain/auto-sub/transfer-hit aggregation); ships the core loop fastest | We don't own the per-player scoring formula; can't diverge from FPL rules without first building (b); a single upstream field we depend on |
| **(b) Compute per-player points ourselves now** | Richest engineering surface; full ownership; the only path to custom scoring variants; a real transform to test | Significant code, especially the BPS bonus system; an ongoing correctness obligation we must defend as a tracked SLI; must track FPL rule changes between seasons; slower to a working core loop — premature for a pre-code project |
| **Hybrid: compute ourselves, reconcile against FPL as oracle** | Best of both *eventually* — ownership **and** a free correctness oracle | Strictly more work than (a) with no extra payoff until the analysis matters; right as a Phase 2 evolution, wrong as the starting point. **This is exactly what (a)'s hedges set up.** |

## Consequences

- **Positive:** The core scoring loop is correct on day one and cheap to build, so effort goes to the
  parts that actually generate the data we care about (lineups, transfers, identity stitching). We
  still practise meaningful transformation logic in the manager-level aggregation. Capturing the
  component stats now means the future compute engine is an additive Phase 2 exercise with a
  built-in test oracle — a clean, low-risk learning stretch rather than a rewrite.
- **Negative / tradeoffs:** We are coupled to FPL's `event_points` as an upstream field; if FPL
  changes its shape or stops publishing it mid-season, the core score breaks (mitigation: the
  component stats we already ingest are the fallback to compute from). We cannot offer custom scoring
  variants until the Phase 2 engine exists. We accept both — neither blocks the data goals.
- **Follow-ups:**
  - ADR-0010 (`dlt` ingestion) — Bronze job must land both `event_points` **and** the per-player
    component stats from the FPL element-summary / event payloads.
  - ADR-0005 (dbt) — owns the manager-level scoring models (`fct_gameweek_scores`): captain doubling,
    auto-subs, transfer penalties; and, in Phase 2, the parallel compute-and-reconcile engine.
  - ADR-0012 (SLO) — if/when the Phase 2 engine lands, the FPL-vs-ours reconciliation becomes a
    registered **correctness** SLI/test; until then there is no scoring correctness obligation to
    defend (correctness is by construction).
  - [`../product/game-design.md`](../product/game-design.md) §4 remains the living scoring spec; this
    ADR fixes *where the per-player number comes from*, not the rule values themselves.

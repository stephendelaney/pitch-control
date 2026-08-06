# ADR-0024: Gold grain — unpivot two-sided facts, densify before windowing

- **Status:** Accepted
- **Date:** 2026-08-05 · ratified 2026-08-06
- **Deciders:** Stephen Delaney
- **Tags:** data-platform, transform, modeling, correctness

## Context

Gold is where the Medallion stops conforming and starts answering
([ADR-0003](0003-s3-parquet-medallion-lake.md)). Silver's job was to mirror FPL faithfully —
typed, renamed, reduced to one committed snapshot ([ADR-0023](0023-silver-snapshot-semantics.md))
— and it does. The problem is that FPL's shape and the questions asked of it are not the same
shape, in two specific ways:

- **A fixture is two-sided.** `stg_fpl__fixtures` is one row per match, carrying
  `home_team_id`/`away_team_id`, `home_team_difficulty`/`away_team_difficulty`,
  `home_score`/`away_score`. Every question anyone actually asks is team-shaped — *their* next
  five, *their* home record, *their* difficulty run — and each one has to reach into both halves
  and pick a side.
- **A fixture list is sparse.** A team-gameweek with no match has no row at all. That is the
  correct representation of a schedule, and it is the wrong input to a window function that is
  supposed to mean "the next five gameweeks".

Both are faithful upstream representations. Both make the natural query **wrong by default
rather than merely awkward**, which is what makes this a decision rather than a style
preference. Four forces:

1. **Every consumer re-derives the same logic.** A team-shaped question against a two-sided row
   needs the same `case when home_team_id = ? then … else …` ladder in every query, every
   dashboard and every downstream model — written independently each time, from memory.
2. **The failure mode is silent and plausible.** A mis-picked branch or a missing row yields a
   number in the right range, not an error. Measured during this build: mis-copying **one line**
   into the away branch of the unpivot corrupted **271 of 380** fixtures — and left the other
   109 correct, because those happen to have equal difficulty on both sides. Nothing about the
   output would have looked wrong.
3. **The next consumer is a point-and-click BI tool.** Wk 4 puts Metabase
   ([ADR-0008](0008-metabase-bi.md)) on Gold. A query author who is a UI cannot express a
   branch ladder or a densifying cross join at all, so any logic left in the consumer layer is
   logic that Metabase simply cannot apply.
4. **One of the two traps is currently unreachable.** There are **no blank or double gameweeks
   in the 2026/27 fixture list** — 380 fixtures, all scheduled, every team playing exactly once
   per gameweek. The sparse-grid bug therefore cannot be observed today. It arrives with the
   first cup-tie reschedule, by which point the reason for the cross join is long forgotten.
   That is precisely the situation an ADR is for.

## Decision

**Gold models will carry the grain the *question* has, not the grain the source has**, even when
that means restating or materialising rows Silver does not have. Two concrete rules follow, and
each is guarded by a singular test verified to fail when violated:

1. **A two-sided fact is unpivoted to one row per participant.** `fct_team_fixture` is 760 rows
   — one per team per fixture — with `difficulty` already from that team's point of view.
   Guarded by `assert_fixture_sides_balance`.
2. **A model that windows over a sequence densifies that sequence first.**
   `mart_team_fixture_run` cross joins teams × gameweeks (20 × 38 = 760) *before* folding
   fixtures onto the grid, so `rows between current row and 4 following` counts **gameweeks** by
   construction rather than by luck. Guarded by `assert_fixture_run_grid_is_complete`.

Absence in a densified model is represented by an **explicit flag** (`is_blank`,
`fixture_count = 0`), never by the row's absence and never by a null alone.

## Options considered

| Option | Pros | Cons |
|---|---|---|
| **A. Grain follows the question — unpivot and densify in Gold (chosen)** | The logic exists once, in a tested model; team-shaped questions become `where team_id = ?` and a plain aggregate; window frames mean what they say; Metabase can consume it without expressing anything clever; a blank gameweek is a visible row rather than a silent gap | Row multiplication (760 vs 380); the side mapping is stated twice in a `union all`, which is a copy-paste hazard; the dense grid materialises rows carrying no fact, which reads as "missing data" to anyone who does not know the convention |
| B. Keep Silver's grain; each consumer picks its own side and handles gaps | No new models; no duplicated rows; Gold stays thin | The re-derivation and the silent-failure mode are the whole problem — this is the status quo the decision exists to reject; and it is **impossible** in Metabase, which cannot author the required SQL |
| C. Keep Silver's grain; publish macros/views for the common pivots | Logic is centralised without materialising rows | A macro is only used by whoever remembers it exists; a view over S3 Parquet is not a lake artifact, so it is invisible to any consumer that reads the bucket rather than this dbt project — and the BI tool is exactly such a consumer |
| D. Densify at query time in the BI tool | No storage cost; grid built only when needed | Pushes the subtlest correctness rule in the layer into the least testable place; Metabase's query builder cannot express a cross join against a gameweek spine; no test could ever cover it |
| E. Unpivot but leave the grid sparse | Half the benefit, none of the row multiplication | The sparse grid is the *dangerous* half: a `rows` frame silently spanning six gameweeks for one team and five for the rest, producing plausible averages throughout |

## Consequences

- **Positive:** Team-shaped questions are one predicate and one aggregate, in SQL or in a BI
  tool. Window frames over gameweeks are correct by construction rather than by coincidence of
  the current fixture list. Both rules are enforced by tests that have been *falsified*, not
  merely written. Blank and double gameweeks — the two things that break naive fixture analysis
  — become explicit columns (`is_blank`, `is_double`, `fixture_count`) instead of shapes a
  consumer has to infer.

- **Negative / tradeoffs:** We accept **row multiplication**: 760 rows where Silver has 380, and
  a dense grid that materialises 760 rows to describe at most 380 matches. At this scale that is
  ~20 KB and irrelevant, but the multiplier is structural, not constant — a player × gameweek
  grid would be 568 × 38 = **21,584 rows**, and a player × fixture fact from `event_live` larger
  again. This decision does **not** license densifying every future model; it licenses
  densifying a model that windows over the sequence being densified.

  We also accept that the side mapping in `fct_team_fixture` is **written twice**, once per
  branch of the `union all`. That is a genuine copy-paste hazard and the reason
  `assert_fixture_sides_balance` checks symmetry rather than just row counts. A `unpivot`
  construct would state it once but would not carry the per-side semantics (`difficulty` means a
  different source column on each side), so the duplication is the honest form.

  Finally, a densified row that carries no fact will look like missing data to a reader who does
  not know the convention. Mitigated by flagging absence explicitly and by keeping
  `avg_difficulty` **null** on a blank rather than zero — zero would sort as the easiest
  gameweek of the season.

- **Follow-ups:**
  - **`event_live` lands a player × fixture fact** (ADR-0017's scoring oracle) with the first
    played gameweek. Decide *then* whether rule 2 applies to it — the presumption is **no**: an
    absent player-gameweek is genuinely absent (the player did not feature), not a blank in a
    schedule, so densifying would invent rows asserting a player existed in a squad. Rule 1
    probably does apply, since a match stat is two-sided in the same way.
  - **The identity marts** ([ADR-0013](0013-identity-stitching.md) — `dim_identity_map`,
    `mart_manager_360`) are blocked on the app layer. When they land, `mart_manager_360` joins
    through the identity spine at manager grain and this ADR is the precedent for choosing that
    grain from the question rather than from the source table.
  - **Metabase (Wk 4)** is the first real test of whether the grain choice was right. If a
    dashboard still needs a custom SQL question to answer a team-shaped question, the grain is
    wrong and this ADR should be amended.

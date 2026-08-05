# `transform/` — Silver/Gold with dbt-duckdb (Wk 3)

dbt models that turn Bronze into a typed, conformed, tested Silver layer in the lake, and Silver
into analytical Gold. **All business logic lives here** — Bronze stays source-faithful
([ADR-0003](../docs/adr/0003-s3-parquet-medallion-lake.md)), so anything that renames, types,
deduplicates or joins is a model in this directory.

| | |
|---|---|
| Tool | dbt-core + `dbt-duckdb` ([ADR-0005](../docs/adr/0005-dbt-transformations.md)) |
| Engine | DuckDB, in-process, no standing warehouse ([ADR-0004](../docs/adr/0004-duckdb-warehouse-engine.md)) |
| Reads | `s3://<lake>/bronze/fpl/**.jsonl.gz` |
| Writes | `s3://<lake>/silver/<model>.parquet`, `s3://<lake>/gold/<model>.parquet` |
| Identity | Ambient credential chain — OIDC in CI, the maintainer's IAM profile locally |

## Run it

```bash
cd transform
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt

export PITCH_CONTROL_LAKE_BUCKET=$(cd ../infra && terraform output -raw lake_bucket)
dbt build                            # 16 models + 148 tests, ~37s against S3
```

`PITCH_CONTROL_LAKE_BUCKET` is the same single switch the ingest layer uses, with the same
semantics: set it and everything is S3, unset it and everything is local disk. `dbt debug`
prints the resolved `external_root`, which is the fastest way to confirm which one you are on.

There is one extra knob, `PITCH_CONTROL_BRONZE_LOCAL`, which overrides *only* the Bronze read
path. It exists for the case that comes up constantly while developing a model: read the real
lake, write Parquet to local disk, touch nothing in S3.

```bash
mkdir -p _local_silver _local_gold   # DuckDB writes files, it does not create directories
unset PITCH_CONTROL_LAKE_BUCKET
export PITCH_CONTROL_BRONZE_LOCAL=s3://<lake>/bronze/fpl
dbt build
```

No secrets and no per-machine setup: `profiles.yml` is committed, lives in this directory (dbt
checks the working directory before `~/.dbt`), and gets its S3 access from
`provider: credential_chain` — DuckDB resolving credentials the same way boto3 does
([ADR-0019](../docs/adr/0019-secret-management.md)).

## What lands

`s3://<lake>/silver/<model>.parquet` and `s3://<lake>/gold/<model>.parquet` — one file per
model, overwritten in full on every build. Full-rebuild rather than incremental is ADR-0003's
stated posture for an object store with no table format: it is idempotent, and at this size
(318 KB across both layers) there is nothing to optimise.

### Silver — conform (163 KB)

| Model | Rows | Source |
|---|---:|---|
| `stg_fpl__players` | 568 | `elements` — the spine; ~104 conformed columns |
| `stg_fpl__fixtures` | 380 | `fixtures` |
| `stg_fpl__gameweeks` | 38 | `events` |
| `stg_fpl__stat_types` | 26 | `element_stats` |
| `stg_fpl__teams` | 20 | `teams` |
| `stg_fpl__phases` | 11 | `phases` |
| `stg_fpl__chips` | 8 | `chips` |
| `stg_fpl__loads` | 6 | `_dlt_loads` — the load ledger, full history |
| `stg_fpl__positions` | 4 | `element_types` |
| `stg_fpl__game_settings` | 1 | `game_meta` |

### Gold — decide (155 KB)

| Model | Rows | Grain | What it answers |
|---|---:|---|---|
| `dim_player` | 568 | player | Who is this, what do they cost, can I pick them |
| `dim_team` | 20 | club | Strength, league position, squad depth and price range |
| `fct_team_fixture` | 760 | team × fixture | The season from both dugouts |
| `mart_team_fixture_run` | 760 | team × gameweek | Fixture difficulty, with a rolling 5-gameweek outlook |
| `mart_player_value` | 568 | player | Points per million, rank in position, ownership, the club's next five |
| `mart_position_scarcity` | 4 | position | Supply, price floor, and what a legal squad costs |

`materialized: external` is what puts Parquet in the lake rather than tables in a DuckDB file:
dbt writes the file, then defines a view over it so `ref()` and tests keep working. The local
`pitch_control.duckdb` holds those views and no data — it is disposable.

Silver's write path is `external_root` from `profiles.yml`, which is a single value per target.
Gold cannot share it, so each Gold model calls `{{ config(location=gold_location()) }}` in its
own header. That has to be per-model rather than a `+location` in `dbt_project.yml`: dbt renders
the project file at load time, **before user macros are registered** (it fails with
`'gold_location' is undefined`) and with no `this` in scope to name the file — so a
project-level setting would put all six models at the same path even if the macro resolved.

## The two rules this layer exists to get right

### Silver reads one committed snapshot

Bronze is append-only and every run appends a **full re-snapshot**, so a player appears once per
load. Reducing that to one row per key has two defensible answers, and the choice is not
cosmetic:

- **latest observation per key** — an entity FPL *removes* keeps its last observation forever,
  so Silver silently accumulates things that no longer exist upstream.
- **the latest complete snapshot** (chosen) — a disappearance shows up honestly as a row-count
  change.

Not hypothetical: the player count has moved 564 → 567 → 568 across the first six loads while
FPL adds players pre-season.

The snapshot is identified from **dlt's `_dlt_loads` ledger filtered to `status = 0`**, not from
`max(load_date)`. A run that dies mid-write leaves data files behind but never gets its ledger
row, so it can never be selected — which is what makes "take one whole load" safe.

Because every model resolves that independently at run time, a load committing *mid-build*
could hand different models different snapshots, producing a Silver layer that is internally
inconsistent without any single model looking wrong. That race is what
`tests/assert_silver_reads_one_committed_snapshot.sql` is for.

### The split null rule

From the Bronze contract ([`ingest/README.md`](../ingest/README.md)) — and it is two rules, not
one:

> A **column** that is NULL is absent from the row. A `null` **inside** a JSONB document is
> preserved.

The first half is handled in two places:

- **`union_by_name=true`** on the source (`models/sources.yml`) covers a column missing from
  *some* loads. Without it DuckDB takes its schema from the first file it reads and silently
  drops any column that appeared later — wrong data, not an error.
- **`optional_column`** (`macros/bronze.sql`) covers a column missing from *all* of them, where
  the model would simply fail to compile. The tempting fix is to delete the column from the
  model, which quietly changes the schema every consumer reads. Instead the column is emitted as
  a typed NULL, so Silver's shape does not move when the data arrives.

Four columns are in that state right now, all because pre-season makes them null for every row:
`fixtures.team_h_score`, `fixtures.team_a_score`, `elements.ep_this`,
`elements.chance_of_playing_this_round`. Every one appears on the first matchday.

The **second** half is not implemented here, because it is the opposite rule — inside a payload,
a missing key is *meaningful* and must not be read as null. It applies to `bronze/postgres/`,
which has no data yet.

## The two things Gold gets right that Silver could not

### Fixtures have two sides, and the grain should say so

Silver's `stg_fpl__fixtures` is one row per match, with `team_h` / `team_a`,
`team_h_difficulty` / `team_a_difficulty`, `team_h_score` / `team_a_score`. That is faithful to
FPL and wrong for almost every question anyone asks of it, because the questions are
team-shaped: *their* next five, *their* home record, *their* difficulty run. Each one has to
reach into both halves and pick a side, and every consumer that does it re-implements the same
`case when team_h = ? then … else …` ladder. Get one branch wrong and the number is subtly and
silently wrong for half the league.

`fct_team_fixture` unpivots to 760 rows — the season seen from both dugouts — and all of those
become `where team_id = ?` plus a plain aggregate. The price is stating the mapping twice, once
per side of the `union all`, which is precisely the thing `assert_fixture_sides_balance` checks.
When that test was falsified by mis-copying one line into the away branch it caught **271 of
380** fixtures — the other 109 happen to have equal difficulty on both sides, which is a fair
illustration of why the check is not optional.

### A blank gameweek is a missing row, and a `rows` window frame cannot see it

`mart_team_fixture_run` computes its outlook with
`rows between current row and 4 following`, partitioned by team and ordered by gameweek. A
`rows` frame counts **rows**, not gameweeks. It only means "the next five gameweeks" because
every team has exactly one row per gameweek — which is true because the model **cross joins
teams to gameweeks before it touches a fixture**.

The tempting simplification is to group `fct_team_fixture` by team and gameweek instead. It
looks identical and passes every other test. But a team with a *blank* gameweek — no fixture,
because their match was moved for a cup tie — would simply have no row, and their window would
silently span six real gameweeks while everyone else's spans five. Every number would still be
a plausible 1-5 difficulty average. `assert_fixture_run_grid_is_complete` holds the grid.

There are **no blanks or doubles in the current fixture list**, which is exactly why this is
written down: the bug is unreachable today and arrives with the first cup-tie reschedule, by
which point nobody will remember why the cross join is there.

## ⚠️ Pre-season, FPL's points are *last season's*

The obvious assumption about a pre-season lake is that the scoring columns are zero — the way
`event_live` correctly loads no rows. They are not, and this is the sharpest trap in the FPL
payload.

Measured against the live lake: **zero gameweeks are finished, and 400 of 568 players carry
non-zero `total_points`, with a maximum of 38 `starts` and 3,420 `minutes`** — a full 38-game
season. FPL keeps the previous season's aggregates in `bootstrap-static` until it resets them
shortly before GW1, so `total_points`, `minutes`, `points_per_game` and the whole contribution
block currently describe **2025/26**.

That is worse than zeros, because zeros are obviously unusable and these numbers look perfectly
usable. And they hang off the player's **current** club: Semenyo shows 3,200 minutes and 202
points against MCI, none of which he played there. Any team-level roll-up is therefore wrong in
a way no test on the mart can detect, because every individual value is valid.

So `mart_player_value.points_are_prior_season` labels it, and the label is derived from
**evidence** — a player has minutes while no gameweek has been played, which cannot happen
inside one season — rather than from FPL's flags (all three are false pre-season) or the
calendar (FPL's reset moment is unannounced). `form` is the tell: it is a 30-day rolling window,
so it expires rather than carries over, and a payload where `form` is empty for all 568 while
`total_points` is not is a payload straddling two seasons.

The same caveat applies to `strength_attack_*` and `strength_defence_*`, which are **0 for all
20 clubs** right now — only `strength_overall_home/away` is populated. Those columns are kept
rather than dropped for the `optional_column` reason: a dashboard built on a schema that gains
two columns in September is a dashboard that breaks in September.

## Typing

FPL sends decimals as **strings** (`form`, `ict_index`, `expected_goals`, `selected_by_percent`,
`value_form`, the whole xG family). Bronze preserves that faithfully because Bronze must not
fail a write on drift; casting is Silver's job.

`nullif(trim(x), '')` handles FPL's habit of sending `""` for "no value yet". The cast is then a
plain `cast`, deliberately **not** a `try_cast`: if FPL ever puts something genuinely
non-numeric in a numeric field, this build should fail loudly and spend error budget
([ADR-0012](../docs/adr/0012-slo-error-budget-policy.md)) rather than quietly write NULLs that
are indistinguishable from real absence.

## Tests

`dbt build` runs 148. Most are schema tests — uniqueness and not-null on every key,
`relationships` on every FK, `accepted_values` on FPL's availability codes and difficulty scale.
The other seven are singular tests carrying invariants that a column-level test cannot express,
and **each has been verified to fail when its invariant is violated** (a test that cannot fail
is worse than no test):

| Test | Layer | Guards | Falsified by |
|---|---|---|---|
| `assert_silver_reads_one_committed_snapshot` | Silver | Every model drew from the same, single, committed load | — |
| `assert_optional_columns_are_typed` | Silver | The split-null-rule columns still exist *and* still carry their cast | — |
| `assert_squad_rules_agree` | Silver | `element_types` and `game_settings` describe the same game | — |
| `assert_fixture_sides_balance` | Gold | The two sides of a fixture agree on opponents, difficulty and goals | mis-copying one line into the away branch → 271 failures |
| `assert_fixture_run_grid_is_complete` | Gold | 20 × 38 with no gaps, so a `rows` frame counts gameweeks | dropping GW20 from the grid → 21 failures |
| `assert_minimum_squad_fits_budget` | Gold | A legal squad is buyable, with room to make choices | summing the *dearest* fill → £125m against a £100m budget |
| `assert_prior_season_points_are_flagged` | Gold | The provenance label matches the evidence, and is global | hardcoding the flag `false` |

One project-local generic test, `unique_combination_of_columns` (`macros/generic_tests.sql`),
covers composite grain — `fct_team_fixture` has no single unique column, since `fixture_id`
appears twice by design. It is deliberately name-compatible with the dbt_utils test of the same
name; taking the package to get one twelve-line macro is not yet a trade worth making, and when
a second or third dbt_utils test is genuinely wanted that file is deleted.

`assert_minimum_squad_fits_budget` is the one that reads like a game-design test rather than a
data test, and it is both. FPL forces 2/5/5/3 inside £100.0m; the cheapest legal squad currently
costs **£64.0m, leaving £36.0m of discretionary money** — which is the headroom that makes the
game a game. Both sides of that comparison move independently and neither is ours: prices rise
all season, the cheap end thins out as FPL removes departed players, and the budget is a value
FPL publishes. ADR-0018 says we mirror FPL rather than invent, so if those drift into
contradiction the build should fail rather than publish a mart describing an unplayable game.

That last one is worth a note. The squad rules appear twice in FPL's API — as per-position
counts and as flat totals — in different payloads, with nothing upstream guaranteeing they
agree. [ADR-0018](../docs/adr/0018-transfer-economy-model.md) says we *mirror* FPL's rules
rather than invent them, so if the two drift apart the game's validation and its stated budget
stop describing the same game. This is also why `stg_fpl__game_settings` exists at all: the
numbers in [`docs/product/game-design.md`](../docs/product/game-design.md) §5 (squad 15, lineup
11, 3 per club, £100.0m, sell-on fee 0.5) live here as **data** rather than as constants copied
into a spec that can drift without anyone noticing. All six currently agree.

## Not here yet, and why

- **The identity marts.** [ADR-0013](../docs/adr/0013-identity-stitching.md)'s centrepiece —
  `dim_identity_map` and `mart_manager_360` — needs app and PostHog data that does not exist
  yet. The Gold that is here is the FPL-only half: everything about players, clubs and fixtures,
  and nothing about *managers*, because there are no managers. It lands with the app layer.
- **`bronze_postgres` sources.** The Postgres→Bronze pipeline is live and proven, but the app
  layer does not exist, so both tables are empty and dlt has written no data files — only its
  own metadata. A source over `bronze/postgres/<t>/` would glob zero files, and DuckDB errors on
  a no-match glob. Declaring it now would be a broken build, not a placeholder.
- **`event_live`.** Same reason, on the FPL side: pre-season selects no gameweeks, so the
  collection has no objects in the lake at all. It is the source of ADR-0017's scoring oracle
  and lands with the first played gameweek.
- **CI.** Running `dbt build` in Actions needs an IAM grant that does not exist yet — see
  [`docs/STATUS.md`](../docs/STATUS.md). `pitch-control-ingest` can write `bronze/*` and nothing
  else, which is correct for ingest and insufficient for transform.

# `transform/` — Silver/Gold with dbt-duckdb (Wk 3)

dbt models that turn Bronze into a typed, conformed, tested Silver layer in the lake.
**All business logic lives here** — Bronze stays source-faithful
([ADR-0003](../docs/adr/0003-s3-parquet-medallion-lake.md)), so anything that renames, types,
deduplicates or joins is a model in this directory.

| | |
|---|---|
| Tool | dbt-core + `dbt-duckdb` ([ADR-0005](../docs/adr/0005-dbt-transformations.md)) |
| Engine | DuckDB, in-process, no standing warehouse ([ADR-0004](../docs/adr/0004-duckdb-warehouse-engine.md)) |
| Reads | `s3://<lake>/bronze/fpl/**.jsonl.gz` |
| Writes | `s3://<lake>/silver/<model>.parquet` |
| Identity | Ambient credential chain — OIDC in CI, the maintainer's IAM profile locally |

## Run it

```bash
cd transform
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt

export PITCH_CONTROL_LAKE_BUCKET=$(cd ../infra && terraform output -raw lake_bucket)
dbt build                            # 10 models + 66 tests
```

`PITCH_CONTROL_LAKE_BUCKET` is the same single switch the ingest layer uses, with the same
semantics: set it and everything is S3, unset it and everything is local disk. `dbt debug`
prints the resolved `external_root`, which is the fastest way to confirm which one you are on.

There is one extra knob, `PITCH_CONTROL_BRONZE_LOCAL`, which overrides *only* the Bronze read
path. It exists for the case that comes up constantly while developing a model: read the real
lake, write Parquet to local disk, touch nothing in S3.

```bash
mkdir -p _local_silver          # DuckDB writes files, it does not create directories
unset PITCH_CONTROL_LAKE_BUCKET
export PITCH_CONTROL_BRONZE_LOCAL=s3://<lake>/bronze/fpl
dbt build
```

No secrets and no per-machine setup: `profiles.yml` is committed, lives in this directory (dbt
checks the working directory before `~/.dbt`), and gets its S3 access from
`provider: credential_chain` — DuckDB resolving credentials the same way boto3 does
([ADR-0019](../docs/adr/0019-secret-management.md)).

## What lands

`s3://<lake>/silver/<model>.parquet` — one file per model, overwritten in full on every build.
Full-rebuild rather than incremental is ADR-0003's stated posture for an object store with no
table format: it is idempotent, and at this size (163 KB total) there is nothing to optimise.

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

`materialized: external` is what puts Parquet in the lake rather than tables in a DuckDB file:
dbt writes the file, then defines a view over it so `ref()` and tests keep working. The local
`pitch_control.duckdb` holds those views and no data — it is disposable.

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

`dbt build` runs 66. Sixty-three are schema tests — uniqueness and not-null on every key,
`relationships` on every FK, `accepted_values` on FPL's availability codes. The other three are
singular tests carrying invariants that a column-level test cannot express, and each has been
verified to fail when its invariant is violated:

| Test | Guards |
|---|---|
| `assert_silver_reads_one_committed_snapshot` | Every model drew from the same, single, committed load |
| `assert_optional_columns_are_typed` | The split-null-rule columns still exist *and* still carry their cast |
| `assert_squad_rules_agree` | `element_types` and `game_settings` describe the same game |

That last one is worth a note. The squad rules appear twice in FPL's API — as per-position
counts and as flat totals — in different payloads, with nothing upstream guaranteeing they
agree. [ADR-0018](../docs/adr/0018-transfer-economy-model.md) says we *mirror* FPL's rules
rather than invent them, so if the two drift apart the game's validation and its stated budget
stop describing the same game. This is also why `stg_fpl__game_settings` exists at all: the
numbers in [`docs/product/game-design.md`](../docs/product/game-design.md) §5 (squad 15, lineup
11, 3 per club, £100.0m, sell-on fee 0.5) live here as **data** rather than as constants copied
into a spec that can drift without anyone noticing. All six currently agree.

## Not here yet, and why

- **Gold.** Silver is the whole of this slice. The centrepiece marts
  ([ADR-0013](../docs/adr/0013-identity-stitching.md) — `dim_identity_map`, `mart_manager_360`)
  need app and PostHog data that does not exist; the FPL-only Gold that *is* possible now is the
  next move.
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

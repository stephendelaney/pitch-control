# `ingest/` — Bronze ingestion (Wk 2)

dlt pipelines that land raw source data in the Medallion lake's Bronze layer.
**EL only** — no business logic here; all modelling is dbt in Silver/Gold
([ADR-0005](../docs/adr/0005-dbt-transformations.md)).

| | |
|---|---|
| Tool | dlt ([ADR-0010](../docs/adr/0010-dlt-ingestion.md)) |
| Source | public FPL API ([ADR-0011](../docs/adr/0011-fpl-api-data-source.md)) |
| Target | `s3://<lake>/bronze/fpl/` ([ADR-0003](../docs/adr/0003-s3-parquet-medallion-lake.md)) |
| Runs on | GitHub Actions, daily 06:00 UTC ([ADR-0007](../docs/adr/0007-github-actions-lambda-orchestration.md)) |
| Identity | `pitch-control-ingest` OIDC role — writes `bronze/*` only ([ADR-0020](../docs/adr/0020-iam-authorization-model.md)) |

## Run it

```bash
cd ingest
python -m venv .venv && source .venv/bin/activate
pip install -r requirements-dev.txt

python run_fpl.py --dry-run          # writes ./_local_bronze — no AWS calls at all
pytest -q                            # 20 tests, no network
```

Against the real lake (needs AWS credentials in the environment):

```bash
export PITCH_CONTROL_LAKE_BUCKET=$(cd ../infra && terraform output -raw lake_bucket)
python run_fpl.py
python run_fpl.py --backfill 1-38    # season history, or replay after a schema change
```

`PITCH_CONTROL_LAKE_BUCKET` is the only switch between local and S3. Unset it and the
pipeline writes to disk instead — which is why the CI job asserts it is set before running,
rather than letting a misconfigured run report success having written to a runner that is
about to be destroyed.

There is no `.dlt/secrets.toml` and there should never be one: S3 access comes from OIDC in
CI and the maintainer's IAM profile locally, both via the environment
([ADR-0019](../docs/adr/0019-secret-management.md) — secrets never touch disk).

## What lands

`bronze/fpl/<collection>/load_date=YYYY-MM-DD/<load_id>.<file_id>.jsonl.gz`

Nine tables, one per FPL collection, all append-only:

| Table | Rows (2026-08-01) | Notes |
|---|---:|---|
| `elements` | 564 | players, ~105 fields each |
| `fixtures` | 380 | full season, re-snapshotted each run |
| `events` | 38 | the gameweeks |
| `element_stats` | 26 | the stat vocabulary |
| `teams` | 20 | |
| `phases` | 11 | |
| `chips` | 8 | |
| `element_types` | 4 | GK / DEF / MID / FWD |
| `game_meta` | 1 | `total_players` + `game_settings` + `game_config` |
| `event_live` | 0 pre-season | per-player gameweek points ([ADR-0017](../docs/adr/0017-scoring-source.md) oracle) |

Design points worth knowing before writing Silver:

- **JSONL + gzip, not Parquet.** Bronze keeps the source's native shape so a load is
  replayable and schema drift cannot fail a *write* (ADR-0003). Typing is Silver's job.
  DuckDB reads `.jsonl.gz` directly.
- **`load_date=` is a Hive partition**, so DuckDB's `hive_partitioning` (ADR-0004) exposes it
  as a real column and Silver can prune instead of scanning every load ever made.
- **Nesting is preserved inline** (`max_table_nesting=0`). dlt would otherwise explode nested
  arrays into child tables like `game_meta__game_config__rules__percentile_ranks` — a
  relational transformation that Bronze has no business doing, and one that would silently
  add or drop tables whenever FPL changes its nesting.
- **Null fields are absent, not `null`.** dlt omits keys whose value is null; verified
  lossless (0 non-null source values missing across 564 × 105 fields). A field that is null
  for *every* row has no column at all — in pre-season that is `ep_this` and `squad_number`.
  **Silver must treat a missing column as null, not assume presence.**
- **FPL's own vocabulary is kept** (`elements`, not `players`). Renaming to domain language is
  Silver's job.
- **dlt adds `_dlt_load_id` and `_dlt_id`** to every row. `_dlt_load_id` joins to
  `_dlt_loads/` and is the natural key for "which run produced this".

## Gameweek selection

`event/{gw}/live/` is mutable — points churn during matches, then FPL applies bonus points and
stat corrections until it marks the event `data_checked`. So each run re-fetches every
gameweek that can still move: the current one, the previous one, and any earlier one that is
`finished` but not yet `data_checked`.

The previous gameweek is taken **even once `data_checked` is set**. FPL applies the final
correction and flips the flag between two of our polls, so the newest rows in Bronze can
predate settlement and nothing would ever go back for them. `is_previous` holds for a full
gameweek, which guarantees at least one post-settlement fetch.

Re-fetching is safe because Bronze is append-only: each run appends another *observation*, and
Silver reduces to the latest per `(event_id, element_id)`.

**Pre-season selects nothing and that is a success.** In early August no event is current,
previous, or finished, so `event_live` is a no-op. The logic is in
[`fpl/gameweeks.py`](fpl/gameweeks.py) — pure, and unit-tested against hand-built fixtures
rather than the live API, so the suite does not depend on FPL's uptime or the time of year.

## Not here yet

**Postgres → Bronze** is the other half of Wk 2. It needs more than this job does: ADR-0021's
ephemeral security-group ingress (the runner authorizes its own /32 on 5432, runs, and revokes
via `always()`, with a janitor for orphans — see
[`runbooks/orphaned-sg-rule.md`](../docs/runbooks/orphaned-sg-rule.md)) plus the RDS password
from SSM per ADR-0019. Neither is granted to the ingest role yet; see the closing note in
[`infra/iam_ingest.tf`](../infra/iam_ingest.tf).

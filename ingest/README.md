# `ingest/` — Bronze ingestion (Wk 2)

dlt pipelines that land raw source data in the Medallion lake's Bronze layer.
**EL only** — no business logic here; all modelling is dbt in Silver/Gold
([ADR-0005](../docs/adr/0005-dbt-transformations.md)).

| | |
|---|---|
| Tool | dlt ([ADR-0010](../docs/adr/0010-dlt-ingestion.md)) |
| Sources | public FPL API ([ADR-0011](../docs/adr/0011-fpl-api-data-source.md)) · RDS Postgres, the OLTP system of record ([ADR-0002](../docs/adr/0002-postgres-jsonb-system-of-record.md)) |
| Target | `s3://<lake>/bronze/{fpl,postgres}/` ([ADR-0003](../docs/adr/0003-s3-parquet-medallion-lake.md)) |
| Runs on | GitHub Actions, daily 06:00 UTC ([ADR-0007](../docs/adr/0007-github-actions-lambda-orchestration.md)) |
| Identity | `pitch-control-ingest` OIDC role — writes `bronze/*` only ([ADR-0020](../docs/adr/0020-iam-authorization-model.md)) |

Two jobs, one schedule, no `needs:` between them — FPL is an unofficial third-party API and
Postgres is our own instance, so a bad afternoon for one is not a reason to skip the other.

## Run it

```bash
cd ingest
python -m venv .venv && source .venv/bin/activate
pip install -r requirements-dev.txt

pytest -q                            # 58 tests — no network, no database, no credentials
```

`PITCH_CONTROL_LAKE_BUCKET` is the only switch between local and S3, for both jobs. Unset it
and the pipeline writes to `./_local_bronze` instead — which is why each CI job asserts it is
set before running, rather than letting a misconfigured run report success having written to a
runner that is about to be destroyed.

There is no `.dlt/secrets.toml` and there should never be one: S3 access comes from OIDC in
CI and the maintainer's IAM profile locally, both via the environment
([ADR-0019](../docs/adr/0019-secret-management.md) — secrets never touch disk).

## The run ledger

Both jobs record themselves in the lake ([ADR-0025](../docs/adr/0025-pipeline-run-ledger-in-the-lake.md)):
two records per run under `s3://<lake>/bronze/ops_runs/`, one written before the load and one
written afterwards with `if: always()`. The writer is
[`.github/scripts/ops_ledger.py`](../.github/scripts/ops_ledger.py) — shared with
`transform-build`, stdlib-only, and uploading through the `aws` CLI so it needs no dependency
from either environment's requirements file.

`run_metrics.py` is this side's half of it. It reads the row counts out of dlt's trace and the
peak RSS out of `resource.getrusage`, and leaves them in the file named by
`PITCH_CONTROL_RUN_METRICS` for the finish step to pick up. Two things about that:

- **`getrusage`, not psutil**, even though psutil is installed. psutil reports memory *now*; the
  number the ADR-0007 trip-wire wants is the high-water mark. `ru_maxrss` is kilobytes on Linux
  and **bytes** on macOS — a 1024× difference that looks plausible on either platform, so the
  conversion is platform-switched.
- **No file means the load never got far enough to report**, which is exactly when the finish
  record matters. That is a warning and a record with nulls, never an exception.

Rehearsing the whole seam locally needs one extra variable, and it is easy to miss:

```bash
export PITCH_CONTROL_LEDGER_DIR=/tmp/ledger            # write records to disk, not S3
export PITCH_CONTROL_RUN_METRICS=/tmp/ledger/metrics.json
export PITCH_CONTROL_LEDGER_RUN_KEY="local.$(date +%s)"  # ← without this, nothing pairs

python ../.github/scripts/ops_ledger.py start --pipeline fpl_bronze
python run_fpl.py --dry-run
python ../.github/scripts/ops_ledger.py finish --pipeline fpl_bronze \
    --status success --metrics "$PITCH_CONTROL_RUN_METRICS"
```

`start` and `finish` are two separate processes. In CI `GITHUB_RUN_ID` is what ties them
together; locally there is nothing, so each invocation would mint its own `run_key` and the
pair would never join. The script warns when it happens — but the failure is invisible in CI by
construction, which is why it is written down here rather than left to be rediscovered.

## FPL → Bronze

```bash
python run_fpl.py --dry-run          # writes ./_local_bronze — no AWS calls at all

export PITCH_CONTROL_LAKE_BUCKET=$(cd ../infra && terraform output -raw lake_bucket)
python run_fpl.py
python run_fpl.py --backfill 1-38    # season history, or replay after a schema change
```

### What lands

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

### Gameweek selection

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

## Postgres → Bronze

The other half of Wk 2: a snapshot of the OLTP system of record (ADR-0002) into
`bronze/postgres/`. The dlt part is small — `sql_database` reflects the schemas and the same
Bronze conventions apply — because the interesting work is upstream of dlt, in *reaching* RDS
at all.

```bash
cd ingest
export PITCH_CONTROL_PG_HOST=$(cd ../infra && terraform output -raw rds_address)
export PITCH_CONTROL_PG_PASSWORD=$(op read "op://pitch-control/rds-master/password")
export PITCH_CONTROL_PG_SSLROOTCERT=$PWD/../infra/global-bundle.pem

python run_postgres.py --dry-run     # writes ./_local_bronze — still connects to RDS
python run_postgres.py               # needs PITCH_CONTROL_LAKE_BUCKET, as above
```

`--dry-run` is narrower here than on the FPL side: it drops the AWS *write*, not the source.
There is no offline mode, which is the honest position — the thing most worth proving about
this job is that the network path and the credential work. A local run works because your home
/32 is already in `allowed_cidrs`; CI has to open its own.

### What lands

`bronze/postgres/<schema>_<table>/load_date=YYYY-MM-DD/<load_id>.<file_id>.jsonl.gz`

| Table | Source | Rows (2026-08-04) |
|---|---|---:|
| `app_raw_landing` | `app.raw_landing` | 0 |
| `ops_pipeline_runs` | `ops.pipeline_runs` | 0 |

**Zero rows is the current correct answer**, exactly as `event_live` is on the FPL side: the app
layer (ADR-0014/0015) does not exist yet, so nothing writes to these tables. The path was
verified against the live instance on 2026-08-04 with temporary synthetic rows, which were
removed afterwards. Tables are **discovered, not allowlisted** — a table added by a future app
migration is captured from its first run, because a table nobody remembered to list has no
history to backfill later.

Two contract points beyond the FPL ones:

- **Table names are schema-qualified** (`app.raw_landing` → `app_raw_landing`). dlt's namespace
  is flat, so `app.foo` and `ops.foo` would otherwise collide into one table with a merged
  schema. A single underscore, not `__` — dlt uses `__` for parent/child tables, and
  `app__raw_landing` would read as a child of `app`.
- **JSONB stays one column.** Verified against the live instance: a three-level-deep `payload`
  landed as a single nested JSON value with arrays and inner `null`s intact, and produced no
  child tables. This is `max_table_nesting=0` doing the same job it does for FPL, but it matters
  more here — ADR-0002 makes JSONB the landing pattern for payloads whose shape is *not ours*,
  so normalisation would add and drop Bronze tables as upstream documents drift.

Note the null rule has two halves, and they differ: a **column** that is NULL is absent from the
row (`ops.pipeline_runs.error`), but a `null` **inside** a JSONB document is preserved. Silver
must treat a missing column as null; it must not treat a missing key inside a payload the same
way.

### Full snapshot, not incremental

Every run re-reads every table and appends. That is deliberate: the tables are tiny, a snapshot
needs no per-table knowledge of which column is a watermark, and it cannot miss a late-arriving
or back-dated row the way a high-water mark can. Bronze is append-only, so Silver reduces to the
latest observation per key — the same shape the FPL job uses for `fixtures`.

It does not scale — cost is O(rows × runs). **Trigger to revisit:** when any table passes
~100k rows, switch that table to `dlt.sources.incremental` on its insert timestamp. That is a
real-app problem, not a Wk-2 one.

### Getting to the database

Neither of these is dlt's problem, and both are the reason this half landed after the FPL half:

- **Network** — [ADR-0021](../docs/adr/0021-ci-ingest-network-path.md). OIDC grants IAM
  credentials, not network reach, and RDS is IP-locked. The workflow opens 5432 to the runner's
  own /32, runs, and revokes it, with a start-of-run sweep and a scheduled janitor for the case
  where a hard-killed runner skips the revoke. Implementation:
  [`.github/scripts/sg-ephemeral.sh`](../.github/scripts/sg-ephemeral.sh); failure mode and
  remediation: [`runbooks/orphaned-sg-rule.md`](../docs/runbooks/orphaned-sg-rule.md).
- **Secret** — [ADR-0019](../docs/adr/0019-secret-management.md). The password lives in
  1Password and is seeded into an SSM `SecureString` (`infra/README.md` → *Seeding the runtime
  DB secret*). CI fetches and consumes it inside a single workflow step, so it never reaches
  `$GITHUB_ENV`, a file, or another step.

TLS is `verify-full` on every path, CI and local. The CA bundle is **gitignored** (`*.pem`), so
the workflow curls it at run time — pinning a CA into a public repo is how you end up trusting a
root long after AWS has rotated it.

# ADR-0025: Pipeline run ledger — append to the lake, not the OLTP

- **Status:** ✅ Accepted (ratified 2026-08-08)
- **Date:** 2026-08-08
- **Deciders:** Stephen Delaney
- **Tags:** data-platform, observability, security, slo

## Context

The seed schema has carried an empty table since Wk 1. `ops.pipeline_runs`
([`infra/sql/0001_init.sql`](../../infra/sql/0001_init.sql)) was written for
[ADR-0007](0007-github-actions-lambda-orchestration.md) to record a row per orchestrated run,
and two things consume it: [ADR-0012](0012-slo-error-budget-policy.md)'s pipeline-success and
freshness SLIs, and the ADR-0007 amendment's "step duration as % of the 15-minute Lambda cap"
trip-wire, which is what would tell us a step needs to move to Fargate. Nothing has ever
written to it. Wk 3 is where that debt comes due.

The obvious implementation — have each job `INSERT` a `running` row and `UPDATE` it on
completion — collides with a constraint that did not exist when the table was designed. There
are now **three** jobs to instrument, and only one of them can reach the database:

| Job | Identity | Can reach RDS today? |
|---|---|---|
| `ingest-bronze / postgres` | `pitch-control-ingest` | **Yes** — it is the RDS reader |
| `ingest-bronze / fpl` | `pitch-control-ingest` | No — public HTTPS and an S3 write, nothing else |
| `transform-build` | `pitch-control-transform` | No — reads `bronze/*`, writes `silver/*` + `gold/*` |

Reaching RDS is not a small thing here. It costs the ADR-0019 SSM secret fetch **and** the
[ADR-0021](0021-ci-ingest-network-path.md) ephemeral security-group hole — a /32 opened in front
of a publicly-addressable database and revoked afterwards, with a janitor and a runbook existing
solely to bound the failure mode when the revoke does not happen.

For the FPL job that means giving up a property its design deliberately bought: it was built
first *because* it needs no secret and no network setup, and that is why ADR-0021's machinery
could be isolated to the Postgres slice instead of entangled in everything.

For the transform job it is worse, because the permission does not exist yet and would have to
be created. `pitch-control-transform` would need `ssm:GetParameter`, `kms:Decrypt`,
`rds:DescribeDBInstances` and `ec2:AuthorizeSecurityGroupIngress` —
[ADR-0020](0020-iam-authorization-model.md)'s whole point being that this identity is narrow, and
the SG-authorize grant being the most sensitive one in the account. **The system would be
strictly less safe in order to record that it is working**, which is the wrong direction for an
observability change.

There is also a shape mismatch worth naming independently of the security one. Every consumer of
this ledger is a dbt model reading the lake. Routing the records through Postgres means they
reach those models by being snapshotted back out again — job → RDS → dlt → Bronze → Silver —
three hops to move a fact that originated on the runner and is destined for the lake.

## Decision

**Pipeline jobs will append their run records to the lake, as two immutable records per run —
`start` and `finish` — under `s3://<lake>/bronze/ops_runs/`, joined on a shared `run_key`.**
No job needs a database credential or a network path to RDS to report that it ran.

RDS `ops.pipeline_runs` stays in the schema and stops being CI's ledger: it belongs to the
application layer, whose runs originate inside the database's own trust boundary and have no
such problem. The two are kept namespaced apart (`bronze/ops_runs/` here;
`bronze/postgres/ops_pipeline_runs/` for the dlt snapshot of the RDS table) so Silver can never
confuse them.

Liveness comes from the pair rather than from mutation. An object store has no `UPDATE`, and
this design does not want one: a job that is hard-killed writes a `start` and no `finish`, so
"died without reporting" is a **missing record** rather than a row stuck at `status = 'running'`
that nobody was alive to correct. That is the same fact, detected without depending on the dying
process to report its own death.

## Options considered

| Option | Pros | Cons |
|---|---|---|
| **A (chosen) — append to `bronze/ops_runs/`** | No secret, no SG hole, no RDS reachability for any job; one narrow `s3:PutObject` grant added to the transform role; append-only, matching Bronze (ADR-0003); consumers read it as an ordinary source, no snapshot round-trip | Two records per run instead of one row; a second ledger exists alongside the RDS table, so the boundary between them has to be documented and held; no `UPDATE`, so a correction is a new record |
| B — write to RDS `ops.pipeline_runs` | Faithful to ADR-0002's system-of-record and to the seed schema as designed; `status='running'` + `finished_at IS NULL` expresses liveness directly; one row per run | Requires the RDS secret and an ADR-0021 SG hole in all three jobs; the FPL job loses its no-secret property; `pitch-control-transform` gains SSM/KMS/RDS/SG-authorize, inverting ADR-0020; telemetry travels the most privileged path in the system |
| C — hybrid: RDS from the jobs that already reach it, lake from the rest | No new grants anywhere | Two ledgers for one concept with no principled boundary — the worst outcome, since every consumer must union them and neither is complete |
| D — derive it from the GitHub Actions API | No credential, no network path, no IAM change; run history available retroactively | Cannot supply `rows_processed` or `peak_mem_mb` — nothing outside the process can observe them — so ADR-0012's throughput SLIs stay unfillable; measures the runner, not the load |

## Consequences

- **Positive.** Every job can report itself with the credential it already holds. The FPL job
  keeps the "no secret, no network setup" property it was designed around, and the transform
  role's exception is one `s3:PutObject` on one prefix — no `GetObject`, no reach into
  `bronze/fpl/` or `bronze/postgres/`. Lineage shortens from four hops to one. The ledger is
  append-only like everything else in Bronze, so it needs no new correctness argument.
- **Negative / tradeoffs.**
  - **Two ledgers now exist** and the distinction is a convention, not a constraint. A future
    session that reads `bronze/postgres/ops_pipeline_runs/` expecting CI runs will find an empty
    table and no error.
  - **Pairing is the reader's job.** Silver has to group by `run_key` and pick the two events;
    an unpaired `start` is a signal, not a defect, and a model that inner-joins the pair will
    silently drop exactly the runs that matter most.
  - **Coverage starts after the credential step.** A job that fails during `pip install` or unit
    tests writes no record at all. That is deliberate — GitHub's run history already covers the
    setup half — but it means ledger success rate is not workflow success rate.
  - **`peak_mem_mb` is null for the transform job.** dbt runs in a previous step, so its peak is
    not observable from the step that writes the record. Recording this process's own footprint
    instead would be a plausible-looking wrong number.
  - **`rows_processed` is null for the transform job too**, and this one is upstream's doing:
    dbt-duckdb populates `adapter_response` with `{"_message": "OK"}` and no `rows_affected`, on
    any node type (verified across all 164 nodes of the 2026-08-06 build). Node counts and
    elapsed time carry the signal instead.
  - **A telemetry write failure does not fail the job.** It emits `::warning::` and exits 0, on
    the same reasoning as the row-count reporting in `run_fpl.py` — failing a good load over its
    own bookkeeping trains the maintainer to ignore red. The cost is that a hole in the ledger
    is only as visible as a warning in a run log.
- **Follow-ups.**
  - Silver model (`stg_ops__pipeline_runs`) pairing the two events, then the ADR-0012 SLI and
    ADR-0007 trip-wire models on top. Blocked until records exist: DuckDB errors on a glob
    matching zero files, so the source cannot be declared before the first run writes one.
  - Decide whether the app layer, when it exists, writes to RDS `ops.pipeline_runs` as assumed
    here or joins this ledger. If it joins, this ADR should be amended and the table dropped.
  - A run that crosses midnight lands its two records in different `load_date=` partitions.
    Harmless — pairing is on `run_key`, not the partition — but any Silver model that prunes to
    a date range must read the neighbouring partition or it will manufacture unpaired starts.

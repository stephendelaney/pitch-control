-- dlt's load ledger, conformed. One row per FPL load attempt.
--
-- Kept as a model in its own right rather than inlined, because it is the only thing in the
-- lake that knows a snapshot is *complete*. Every other model here selects one load_id via
-- `latest_completed_load()`; this is the table that says which ids were ever eligible, and it
-- is the natural source for ADR-0012's ingest-freshness SLI ("how long since a committed
-- load?") without opening S3.
--
-- Not filtered to the latest load — the whole point is the history.

select
    load_id,
    schema_name,
    -- dlt writes 0 on commit and nothing else at rest; a non-zero row would mean an
    -- interrupted load, which is precisely what the snapshot rule must exclude.
    status,
    status = 0 as is_committed,
    inserted_at as loaded_at,
    schema_version_hash,

    -- The load_id is epoch seconds as text. Exposing it as a real timestamp makes freshness a
    -- date comparison instead of a string trick, and it is the run's *start* — `loaded_at` is
    -- its commit — so the pair also gives load duration for the ADR-0007 overflow trip-wire.
    to_timestamp(cast(load_id as double)) as load_started_at

from {{ source('bronze_fpl', 'dlt_loads') }}

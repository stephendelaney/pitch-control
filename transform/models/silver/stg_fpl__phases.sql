-- Scoring phases — the month-like windows FPL ranks managers within, plus an "Overall" phase
-- spanning the whole season. Small, but it is the grain the league tables in ADR-0013's
-- manager-360 mart will be cut by.

with snapshot as (

    select *
    from {{ source('bronze_fpl', 'phases') }}
    where _dlt_load_id = ({{ latest_completed_load() }})

)

select
    id as phase_id,
    name as phase_name,

    start_event as first_gameweek_id,
    stop_event as last_gameweek_id,
    (stop_event - start_event) + 1 as gameweek_count,

    _dlt_load_id as load_id

from snapshot

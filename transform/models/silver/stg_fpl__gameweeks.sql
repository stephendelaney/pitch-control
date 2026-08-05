-- The 38 gameweeks. FPL calls them `events`; the game design calls them gameweeks.
--
-- The `finished` / `data_checked` pair is the important part and the two are not the same
-- thing: `finished` means the matches are over, `data_checked` means FPL has applied bonus
-- points and stat corrections and the scores are final. `ingest/fpl/gameweeks.py` re-fetches
-- live points until the second flag is set, so anything downstream that treats a gameweek as
-- settled must read `data_checked`, not `finished`.

with snapshot as (

    select *
    from {{ source('bronze_fpl', 'events') }}
    where _dlt_load_id = ({{ latest_completed_load() }})

)

select
    id as gameweek_id,
    name as gameweek_name,

    deadline_time,
    deadline_time_epoch,

    finished as is_finished,
    data_checked as is_data_checked,
    -- The one flag downstream should actually trust for "these points are final".
    finished and data_checked as is_settled,

    -- Exactly one of each of these is true at a time, and all three are false pre-season —
    -- which is the current state of the lake and the reason `event_live` loads nothing.
    is_previous,
    is_current,
    is_next,

    can_enter,
    can_manage,
    released as is_released,

    average_entry_score,
    ranked_count,
    transfers_made,

    -- Per-gameweek chip usage, kept as JSON text rather than exploded. Bronze holds nesting
    -- inline (ADR-0003) and unpacking this into a fact table is a Gold decision, not a Silver
    -- one — flattening it here would invent a grain this model does not have.
    cast(chip_plays as varchar) as chip_plays_json,

    _dlt_load_id as load_id

from snapshot

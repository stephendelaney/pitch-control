-- Chip definitions (wildcard, bench boost, triple captain, free hit) and the gameweek window
-- each is playable in. ADR-0018 mirrors FPL's transfer/economy rules, so these are the real
-- constraints the game enforces rather than values we chose.

with snapshot as (

    select *
    from {{ source('bronze_fpl', 'chips') }}
    where _dlt_load_id = ({{ latest_completed_load() }})

)

select
    id as chip_id,
    name as chip_name,
    chip_type,
    number as chip_number,

    start_event as first_gameweek_id,
    stop_event as last_gameweek_id,

    -- The scoring/rule overrides a chip applies while active, kept as JSON text. Deeply nested
    -- and sparsely populated; modelling it is only worth doing once something reads it.
    cast(overrides as varchar) as overrides_json,

    _dlt_load_id as load_id

from snapshot

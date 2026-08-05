-- The vocabulary of stats FPL scores on: a label/name lookup, not a fact table.
--
-- `name` is the machine key used inside `fixtures.stats_json` and the live-points payloads, so
-- this is the join target when those blobs are eventually unpacked in Gold — which is the
-- reason a nine-row lookup earns a model of its own.

with snapshot as (

    select *
    from {{ source('bronze_fpl', 'element_stats') }}
    where _dlt_load_id = ({{ latest_completed_load() }})

)

select
    name as stat_key,
    label as stat_label,

    _dlt_load_id as load_id

from snapshot

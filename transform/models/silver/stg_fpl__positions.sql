-- Positions (GKP/DEF/MID/FWD) and the squad rules attached to each.
--
-- FPL calls these `element_types`. Renaming to domain language is Silver's job (Bronze keeps
-- the source vocabulary — ADR-0003), and "position" is what the game design calls it.

with snapshot as (

    select *
    from {{ source('bronze_fpl', 'element_types') }}
    where _dlt_load_id = ({{ latest_completed_load() }})

)

select
    id as position_id,
    singular_name as position_name,
    singular_name_short as position_short_name,
    plural_name as position_name_plural,

    -- The squad constraints in docs/product/game-design.md §squad are these numbers, not
    -- constants we invented: how many of this position a squad must hold, and the min/max that
    -- may be fielded in a starting XI.
    squad_select as squad_required,
    squad_min_play as lineup_min,
    squad_max_play as lineup_max,

    element_count as player_count,

    _dlt_load_id as load_id

from snapshot

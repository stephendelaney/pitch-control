-- The 20 Premier League clubs, from the latest committed snapshot.
--
-- FPL's `id` is season-scoped and its `code` is the stable cross-season club identifier. Both
-- are kept: `team_id` is what every other FPL payload joins on, `team_code` is what survives
-- into next season.

with snapshot as (

    select *
    from {{ source('bronze_fpl', 'teams') }}
    where _dlt_load_id = ({{ latest_completed_load() }})

)

select
    id as team_id,
    code as team_code,
    name as team_name,
    short_name as team_short_name,

    -- `position` is a reserved word in enough engines to be worth renaming once, here.
    position as league_position,
    played as matches_played,
    win as wins,
    draw as draws,
    loss as losses,
    points as league_points,

    -- FPL's own 1-5 difficulty inputs, split home/away. These drive fixture difficulty and are
    -- the reason `fixtures` can carry a difficulty rating per side.
    strength_overall_home,
    strength_overall_away,
    strength_attack_home,
    strength_attack_away,
    strength_defence_home,
    strength_defence_away,

    unavailable as is_unavailable,
    pulse_id,

    -- Lineage: which Bronze load this row came from. Joins to stg_fpl__loads, and is the
    -- answer to "which run produced this" for every row in Silver.
    _dlt_load_id as load_id

from snapshot

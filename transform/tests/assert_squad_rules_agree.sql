-- Cross-payload consistency: the squad rules appear twice in FPL's API and nothing upstream
-- guarantees the two agree.
--
-- `element_types` says how many of each position a squad holds (2 GK, 5 DEF, 5 MID, 3 FWD) and
-- how many of each may be fielded. `game_settings` states the squad size (15) and lineup size
-- (11) as flat numbers. They are produced by different parts of FPL and land in different
-- Bronze tables, so "they add up" is an assumption — and it is the assumption ADR-0018 rests
-- on when it says we mirror FPL's rules rather than invent our own.
--
-- If FPL changes one and not the other, the game's validation rules and its stated budget stop
-- describing the same game. That is a correctness bug in the product, not just in the data, and
-- it would otherwise be found by a user building a squad that the rules reject.
--
-- Returns a row per broken invariant. Empty result = pass.

with positions as (

    select
        sum(squad_required) as total_squad_required,
        sum(lineup_min) as total_lineup_min,
        sum(lineup_max) as total_lineup_max
    from {{ ref('stg_fpl__positions') }}

),

settings as (

    select
        squad_size,
        lineup_size
    from {{ ref('stg_fpl__game_settings') }}

),

checks as (

    select
        'squad size' as invariant,
        p.total_squad_required as from_positions,
        s.squad_size as from_settings
    from positions p
    cross join settings s
    where p.total_squad_required <> s.squad_size

    union all

    -- A lineup must be reachable: you cannot field 11 if the per-position minimums already
    -- exceed 11, or if the maximums cannot reach it.
    select
        'lineup size is reachable',
        p.total_lineup_min,
        s.lineup_size
    from positions p
    cross join settings s
    where s.lineup_size < p.total_lineup_min
       or s.lineup_size > p.total_lineup_max

)

select
    invariant,
    from_positions,
    from_settings
from checks

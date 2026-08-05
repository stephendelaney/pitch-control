-- FPL's pre-season payload carries the *previous* season's scoring totals, and says nothing
-- about it. `mart_player_value.points_are_prior_season` is the label that stops a dashboard
-- presenting 2025/26 production as 2026/27 form.
--
-- The label is derived from evidence — a player has logged minutes while no gameweek has
-- finished, which cannot happen within one season — and this test exists because the obvious
-- "simplifications" of that rule are all wrong in ways nothing else would catch:
--
--   * keying off `is_current` / `is_next` — all three FPL flags are false pre-season, which is
--     the state of the lake today;
--   * keying off the calendar or the season rollover date — FPL zeroes the totals at some
--     unannounced point before GW1, so any date-based rule is wrong for that window;
--   * dropping the flag as "obviously true in August" — it becomes false mid-August and stays
--     false for nine months, and a hardcoded `true` would then relabel live data as stale.
--
-- Two invariants:
--
--   1. **The evidence and the label agree.** If any player has minutes while no gameweek is
--      finished, every row must be flagged. If the flag is set, the evidence must be there.
--   2. **The flag is global.** It describes the payload, not the player, so all 568 rows must
--      carry the same value. A stray join or a window over the wrong partition would produce a
--      per-player flag that still looks like a boolean.

with evidence as (

    select
        (select count(*) from {{ ref('stg_fpl__gameweeks') }} where is_finished) = 0
        and (select max(minutes) from {{ ref('dim_player') }}) > 0 as expected_flag

),

actual as (

    select
        count(distinct points_are_prior_season) as distinct_flags,
        min(points_are_prior_season) as flag,
        count(*) as player_count
    from {{ ref('mart_player_value') }}

)

select
    a.flag as labelled,
    e.expected_flag as evidenced,
    a.distinct_flags,
    a.player_count
from actual as a
cross join evidence as e
where
    -- 1. the label matches the evidence
    a.flag is distinct from e.expected_flag

    -- 2. one payload, one answer
    or a.distinct_flags <> 1

-- The 20 clubs, as the dimension everything else in Gold joins to.
--
-- Thin on purpose. Silver already conformed this table, so the only work left is the work Gold
-- is *for*: giving BI a stable surface to join to, and collapsing FPL's six strength ratings
-- into the two or three numbers a human actually reasons with.
--
-- The six ratings are a 3x2 grid — {overall, attack, defence} x {home, away} — and FPL's own
-- fixture difficulty is derived from them. Averaging the home/away pair per facet is a genuine
-- simplification and it is recorded here rather than repeated in three dashboards, which is the
-- whole argument for the layer. The split survives alongside it, because home/away asymmetry is
-- real and a mart that hides it would be lying.
--
-- ⚠️ Only one of the three facets is populated right now. Checked against the live lake:
-- `strength_attack_home/away` and `strength_defence_home/away` are **0 for all 20 clubs**, and
-- only `strength_overall_home/away` carry values (2-4 home, 2-5 away). So `strength_attack` and
-- `strength_defence` below are currently zero columns.
--
-- They are kept anyway, for the same reason `optional_column` exists in Silver: FPL populates
-- them once the season is under way, and a dashboard built on a schema that gains two columns
-- in September is a dashboard that breaks in September. A zero that is honest about being a
-- zero beats a column that appears out of nowhere.

{#- The averaged facets are `/ 2.0` — a deliberate float. The inputs are small ints on FPL's
    1-5 scale and integer division would silently floor a 4/5 split to 4. -#}

{{ config(location = gold_location()) }}

select
    t.team_id,
    t.team_code,
    t.team_name,
    t.team_short_name,

    -- ── strength ────────────────────────────────────────────────────────────────────────
    (t.strength_overall_home + t.strength_overall_away) / 2.0 as strength_overall,
    (t.strength_attack_home + t.strength_attack_away) / 2.0 as strength_attack,
    (t.strength_defence_home + t.strength_defence_away) / 2.0 as strength_defence,

    -- The home/away gap in FPL's overall rating, and named for what it measures rather than
    -- for what you would expect it to mean. It is *not* home advantage: measured against the
    -- live lake it is 0 for twelve clubs and **-1 for the other eight, never positive** —
    -- FPL currently rates every club at least as strong away as at home, and the strongest
    -- clubs (ARS, MCI: 4 home, 5 away) most of all.
    --
    -- Whether that is a pre-season placeholder or FPL's actual view is not knowable from here,
    -- and inventing a `home_advantage` column that is negative or zero for all 20 clubs would
    -- put a confident, wrong label on it. Recheck the sign once a few gameweeks have been
    -- played; if it flips, the ratings were provisional and this column becomes interesting.
    t.strength_overall_home - t.strength_overall_away as home_away_strength_delta,

    t.strength_overall_home,
    t.strength_overall_away,
    t.strength_attack_home,
    t.strength_attack_away,
    t.strength_defence_home,
    t.strength_defence_away,

    -- ── league table ────────────────────────────────────────────────────────────────────
    -- All zero pre-season. That is honest rather than broken: FPL publishes the table as it
    -- stands, and it stands at nothing until a ball is kicked.
    t.league_position,
    t.matches_played,
    t.wins,
    t.draws,
    t.losses,
    t.league_points,

    t.is_unavailable,

    -- ── squad supply ────────────────────────────────────────────────────────────────────
    -- Cheap to compute here and awkward everywhere else: how deep this club's FPL squad is,
    -- and what it costs. `max_players_per_club` (3, from game_settings) is the reason the
    -- second one matters — a club you can only take three of is a budget decision, not a
    -- selection one.
    p.player_count,
    p.available_player_count,
    p.cheapest_player_gbp_m,
    p.dearest_player_gbp_m

from {{ ref('stg_fpl__teams') }} as t
left join (

    select
        team_id,
        count(*) as player_count,
        count(*) filter (where is_available) as available_player_count,
        min(now_cost_gbp_m) as cheapest_player_gbp_m,
        max(now_cost_gbp_m) as dearest_player_gbp_m
    from {{ ref('stg_fpl__players') }}
    group by team_id

) as p on p.team_id = t.team_id

-- Players, denormalised onto club and position. The spine of Gold.
--
-- Silver's `stg_fpl__players` is ~104 columns wide and carries `team_id` / `position_id` as bare
-- integers. Every dashboard, every mart and every ad-hoc question would otherwise repeat the
-- same two joins and the same "what does element_type 3 mean" lookup. Resolving them once is
-- what a conformed dimension is.
--
-- This is deliberately a *dimension*, not the value mart: it answers "who is this player and
-- what do they cost", not "are they worth it". The derived value metrics live in
-- `mart_player_value`, which joins back to here. Keeping them apart means a dashboard that only
-- needs a filter list does not carry the arithmetic, and the arithmetic has one home.
--
-- The column set is the decision-relevant subset of Silver, not all of it. Silver's job was to
-- conform everything faithfully; Gold's job is to choose. Anything dropped here is still one
-- `ref('stg_fpl__players')` away.

{{ config(location = gold_location()) }}

select
    -- ── identity ────────────────────────────────────────────────────────────────────────
    p.player_id,
    p.player_code,
    p.display_name,
    p.full_name,
    p.first_name,
    p.second_name,
    p.birth_date,

    -- ── club ────────────────────────────────────────────────────────────────────────────
    p.team_id,
    t.team_name,
    t.team_short_name,
    t.strength_overall as team_strength_overall,
    t.strength_attack as team_strength_attack,
    t.strength_defence as team_strength_defence,

    -- ── position ────────────────────────────────────────────────────────────────────────
    p.position_id,
    pos.position_name,
    pos.position_short_name,
    -- Carried onto the player row because squad validation asks it per player, not per
    -- position: "can I still fit another one of these?" (ADR-0018 — we mirror FPL's rules, and
    -- these are FPL's numbers, not ours).
    pos.squad_required as position_squad_required,
    pos.lineup_min as position_lineup_min,
    pos.lineup_max as position_lineup_max,

    -- ── price ───────────────────────────────────────────────────────────────────────────
    p.now_cost_tenths,
    p.now_cost_gbp_m,
    p.cost_change_start / 10.0 as price_change_season_gbp_m,
    p.cost_change_event / 10.0 as price_change_gameweek_gbp_m,

    -- ── availability ────────────────────────────────────────────────────────────────────
    p.status,
    p.is_available,
    p.chance_of_playing_next_round,
    p.news,
    p.news_added,

    -- The flag a squad builder actually filters on, and it is not `is_available`. A player can
    -- be fully fit and still be unpickable — FPL sets `can_select` false for players who have
    -- left the league mid-season but are kept in the payload so existing squads still render.
    -- Collapsing the three flags into one here stops every consumer inventing its own rule.
    p.is_selectable and p.is_transactable and not p.is_removed as is_pickable,
    p.is_removed,
    p.is_selectable,
    p.is_transactable,

    -- ── scoring ─────────────────────────────────────────────────────────────────────────
    -- ADR-0017: FPL's `total_points` is the oracle; we ingest it rather than compute it.
    p.total_points,
    p.event_points,
    p.points_per_game,
    p.form,
    p.expected_points_next,
    p.minutes,
    p.starts,
    p.bonus,
    p.bps,

    -- ── contributions ───────────────────────────────────────────────────────────────────
    p.goals_scored,
    p.assists,
    p.clean_sheets,
    p.goals_conceded,
    p.saves,
    p.yellow_cards,
    p.red_cards,
    p.defensive_contribution,

    -- ── expected ────────────────────────────────────────────────────────────────────────
    p.expected_goals,
    p.expected_assists,
    p.expected_goal_involvements,
    p.expected_goals_conceded,
    p.expected_goal_involvements_per_90,

    -- ── ICT ─────────────────────────────────────────────────────────────────────────────
    p.influence,
    p.creativity,
    p.threat,
    p.ict_index,

    -- ── market ──────────────────────────────────────────────────────────────────────────
    p.selected_by_percent,
    p.transfers_in_event,
    p.transfers_out_event,
    p.transfers_in_event - p.transfers_out_event as net_transfers_event,

    -- ── set pieces ──────────────────────────────────────────────────────────────────────
    -- A first-choice penalty taker is worth several points a season over the same player
    -- without the duty, so this belongs on the dimension rather than buried in Silver's width.
    p.penalties_order,
    p.direct_freekicks_order,
    p.corners_and_indirect_freekicks_order,
    p.penalties_order = 1 as is_first_choice_penalties,

    p.load_id

from {{ ref('stg_fpl__players') }} as p
inner join {{ ref('dim_team') }} as t on t.team_id = p.team_id
inner join {{ ref('stg_fpl__positions') }} as pos on pos.position_id = p.position_id

-- Players. FPL's `elements` — the widest object in the source (~105 fields) and the spine
-- everything else joins to.
--
-- Three conforming jobs happen here, and only here:
--
--   1. Typing. FPL sends decimals as *strings* (`form`, `ict_index`, `expected_goals`,
--      `selected_by_percent`, …) — a JSON quirk Bronze preserves faithfully because Bronze
--      must not fail a write on drift (ADR-0003). `nullif(trim(x), '')` handles FPL's habit of
--      sending "" for "no value yet"; the cast is then a plain `cast`, not a `try_cast`, on
--      purpose. If FPL ever sends something genuinely non-numeric in a numeric field, this
--      build should fail loudly and spend error budget (ADR-0012) rather than quietly write
--      NULLs that look like real absence.
--
--   2. Naming. `element_type` is a position, `now_cost` is in tenths of a million.
--
--   3. Presence. `ep_this` and `chance_of_playing_this_round` are null for every player in the
--      lake right now, so they have no columns in Bronze at all. See `optional_column`.
--
-- The column set is deliberately wide rather than curated: Silver's job is to conform, not to
-- decide what Gold is allowed to ask for. Genuinely UI-only fields (`photo`,
-- `has_temporary_code`, the scout-risk blobs) are the exception and stay in Bronze.

{% set available = bronze_columns(source('bronze_fpl', 'elements')) %}

with snapshot as (

    select *
    from {{ source('bronze_fpl', 'elements') }}
    where _dlt_load_id = ({{ latest_completed_load() }})

)

select
    -- ── identity ────────────────────────────────────────────────────────────────────────
    id as player_id,
    -- Season-stable across FPL's own id churn; the right key for cross-season joins later.
    code as player_code,
    first_name,
    second_name,
    first_name || ' ' || second_name as full_name,
    web_name as display_name,
    known_name,
    opta_code,
    birth_date,
    region as region_id,

    -- ── squad membership ────────────────────────────────────────────────────────────────
    team as team_id,
    team_code,
    team_join_date,
    element_type as position_id,

    -- ── price ───────────────────────────────────────────────────────────────────────────
    -- FPL quotes prices in tenths of a million. Both forms are exposed: the raw integer is
    -- what price-change arithmetic must use (it is exact), the derived value is what a human
    -- or a dashboard reads.
    now_cost as now_cost_tenths,
    now_cost / 10.0 as now_cost_gbp_m,
    cost_change_start,
    cost_change_event,
    cost_change_start_fall,
    cost_change_event_fall,
    cast(nullif(trim(price_change_percent), '') as double) as price_change_percent,

    -- ── ownership & transfers ───────────────────────────────────────────────────────────
    cast(nullif(trim(selected_by_percent), '') as double) as selected_by_percent,
    transfers_in,
    transfers_out,
    transfers_in_event,
    transfers_out_event,

    -- ── availability ────────────────────────────────────────────────────────────────────
    -- 'a' available, 'd' doubtful, 'i' injured, 's' suspended, 'u' unavailable.
    status,
    status = 'a' as is_available,
    chance_of_playing_next_round,
    {{ optional_column(available, 'chance_of_playing_this_round', 'bigint') }},
    news,
    news_added,
    removed as is_removed,
    can_select as is_selectable,
    can_transact as is_transactable,
    special as is_special,

    -- ── form & points ───────────────────────────────────────────────────────────────────
    total_points,
    event_points,
    cast(nullif(trim(form), '') as double) as form,
    cast(nullif(trim(points_per_game), '') as double) as points_per_game,
    cast(nullif(trim(ep_next), '') as double) as expected_points_next,
    {{ optional_column(available, 'ep_this', 'double', alias='expected_points_this') }},
    cast(nullif(trim(value_form), '') as double) as value_form,
    cast(nullif(trim(value_season), '') as double) as value_season,
    dreamteam_count,
    in_dreamteam as is_in_dreamteam,

    -- ── season totals ───────────────────────────────────────────────────────────────────
    minutes,
    starts,
    goals_scored,
    assists,
    clean_sheets,
    goals_conceded,
    own_goals,
    penalties_saved,
    penalties_missed,
    yellow_cards,
    red_cards,
    saves,
    bonus,
    bps,
    tackles,
    recoveries,
    clearances_blocks_interceptions,
    defensive_contribution,

    -- ── ICT index (strings upstream) ────────────────────────────────────────────────────
    cast(nullif(trim(influence), '') as double) as influence,
    cast(nullif(trim(creativity), '') as double) as creativity,
    cast(nullif(trim(threat), '') as double) as threat,
    cast(nullif(trim(ict_index), '') as double) as ict_index,

    -- ── expected (xG family, strings upstream) ──────────────────────────────────────────
    cast(nullif(trim(expected_goals), '') as double) as expected_goals,
    cast(nullif(trim(expected_assists), '') as double) as expected_assists,
    cast(nullif(trim(expected_goal_involvements), '') as double) as expected_goal_involvements,
    cast(nullif(trim(expected_goals_conceded), '') as double) as expected_goals_conceded,

    -- ── per-90 rates (already numeric upstream) ─────────────────────────────────────────
    expected_goals_per_90,
    expected_assists_per_90,
    expected_goal_involvements_per_90,
    expected_goals_conceded_per_90,
    goals_conceded_per_90,
    saves_per_90,
    starts_per_90,
    clean_sheets_per_90,
    defensive_contribution_per_90,

    -- ── FPL's own rankings ──────────────────────────────────────────────────────────────
    -- Each comes in two flavours: overall, and `_type` = within the player's position.
    influence_rank,
    influence_rank_type,
    creativity_rank,
    creativity_rank_type,
    threat_rank,
    threat_rank_type,
    ict_index_rank,
    ict_index_rank_type,
    now_cost_rank,
    now_cost_rank_type,
    form_rank,
    form_rank_type,
    points_per_game_rank,
    points_per_game_rank_type,
    selected_rank,
    selected_rank_type,

    -- ── set-piece duty ──────────────────────────────────────────────────────────────────
    corners_and_indirect_freekicks_order,
    corners_and_indirect_freekicks_text,
    direct_freekicks_order,
    direct_freekicks_text,
    penalties_order,
    penalties_text,

    _dlt_load_id as load_id

from snapshot

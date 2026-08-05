-- Four rows — GKP, DEF, MID, FWD — answering "how much choice does this position give me, and
-- what does filling it cost?"
--
-- The question is only interesting because of the constraint. FPL does not let a manager buy
-- the fifteen best players: the squad must hold exactly 2 goalkeepers, 5 defenders, 5
-- midfielders and 3 forwards (ADR-0018 — FPL's numbers, arriving here as `squad_required` from
-- `stg_fpl__positions` rather than as constants typed into this file). So each position is its
-- own little market with its own supply, its own price floor and its own mandatory spend, and
-- the interesting comparisons are between those markets rather than across the whole player
-- pool.
--
-- The budget arithmetic at the bottom is the part worth reading. It computes the cheapest legal
-- squad and compares it to the £100.0m budget, which is the invariant that makes the game
-- playable at all — and `assert_minimum_squad_fits_budget` fails the build if FPL ever prices
-- it out of reach.

{{ config(location = gold_location()) }}

with pickable as (

    -- Only players who can actually be bought. Including the unpickable ones would understate
    -- every price floor below, because a player FPL has retired from the payload keeps their
    -- last price and is frequently the cheapest name in the position.
    select *
    from {{ ref('dim_player') }}
    where is_pickable

),

cheapest_fill as (

    -- The `squad_required` cheapest players in each position, and what they cost together.
    --
    -- This is a lower bound on the cost of filling the position, not a buildable squad: it
    -- ignores the max-3-players-per-club rule, which can only ever push the real figure up.
    -- Stated rather than silently assumed away, because "minimum squad cost" reads like a
    -- constructive answer and this one is not.
    select
        position_id,
        sum(now_cost_gbp_m) as cheapest_fill_gbp_m
    from (
        select
            position_id,
            now_cost_gbp_m,
            row_number() over (
                partition by position_id order by now_cost_gbp_m, player_id
            ) as price_order,
            position_squad_required
        from pickable
    ) as ordered
    where price_order <= position_squad_required
    group by position_id

),

dearest_fill as (

    select
        position_id,
        sum(now_cost_gbp_m) as dearest_fill_gbp_m
    from (
        select
            position_id,
            now_cost_gbp_m,
            row_number() over (
                partition by position_id order by now_cost_gbp_m desc, player_id
            ) as price_order,
            position_squad_required
        from pickable
    ) as ordered
    where price_order <= position_squad_required
    group by position_id

),

supply as (

    select
        pos.position_id,
        pos.position_name,
        pos.position_short_name,
        pos.squad_required,
        pos.lineup_min,
        pos.lineup_max,

        count(p.player_id) as player_count,
        count(p.player_id) filter (where p.is_available) as available_player_count,
        count(distinct p.team_id) as club_count,

        -- ── price distribution ──────────────────────────────────────────────────────────
        min(p.now_cost_gbp_m) as cheapest_gbp_m,
        median(p.now_cost_gbp_m) as median_gbp_m,
        max(p.now_cost_gbp_m) as dearest_gbp_m,
        max(p.now_cost_gbp_m) - min(p.now_cost_gbp_m) as price_spread_gbp_m,

        -- ── scoring distribution ────────────────────────────────────────────────────────
        -- ⚠️ Currently last season's, not this one — see mart_player_value's header for the
        -- evidence and `points_are_prior_season` for the flag. Left unflagged here because
        -- this model's reason to exist is the price and supply arithmetic below, which is
        -- entirely about the season being played.
        max(p.total_points) as best_total_points,
        avg(p.total_points) as avg_total_points,
        max(p.form) as best_form

    from {{ ref('stg_fpl__positions') }} as pos
    left join pickable as p on p.position_id = pos.position_id
    group by all

)

select
    s.position_id,
    s.position_name,
    s.position_short_name,

    -- ── the constraint ──────────────────────────────────────────────────────────────────
    s.squad_required,
    s.lineup_min,
    s.lineup_max,
    -- How much of the starting XI this position can swing. A midfielder slot is worth more
    -- attention than a goalkeeper slot partly because there are more of them.
    s.lineup_max - s.lineup_min as lineup_flexibility,

    -- ── supply ──────────────────────────────────────────────────────────────────────────
    s.player_count,
    s.available_player_count,
    s.club_count,

    -- The scarcity number. Choice per mandatory slot: how many buyable players exist for each
    -- one this position forces you to fill. Goalkeepers are plentiful and only 2 are needed;
    -- forwards are the thinnest market in the game and 3 are compulsory, which is why forward
    -- prices behave the way they do.
    s.player_count / nullif(s.squad_required, 0) as players_per_squad_slot,

    -- ── price ───────────────────────────────────────────────────────────────────────────
    s.cheapest_gbp_m,
    s.median_gbp_m,
    s.dearest_gbp_m,
    s.price_spread_gbp_m,

    -- ── cost to fill ────────────────────────────────────────────────────────────────────
    cf.cheapest_fill_gbp_m,
    df.dearest_fill_gbp_m,
    df.dearest_fill_gbp_m - cf.cheapest_fill_gbp_m as fill_cost_range_gbp_m,

    -- ── scoring ─────────────────────────────────────────────────────────────────────────
    s.best_total_points,
    s.avg_total_points,
    s.best_form,

    -- ── budget, whole-squad ─────────────────────────────────────────────────────────────
    -- Repeated on all four rows on purpose: this mart is what a squad-builder dashboard reads,
    -- and a filter to one position should not make the budget disappear. The window sum is over
    -- the four position rows, so `minimum_squad_gbp_m` is the cheapest legal squad in the game.
    gs.budget_gbp_m,
    gs.squad_size,
    gs.max_players_per_club,
    sum(cf.cheapest_fill_gbp_m) over () as minimum_squad_gbp_m,

    -- What is left to spend on quality once the mandatory floor is paid. This is the number
    -- that makes the whole game a game: it is around 40% of the budget, so most of the money
    -- is genuinely discretionary — and it is what `assert_minimum_squad_fits_budget` watches.
    gs.budget_gbp_m - sum(cf.cheapest_fill_gbp_m) over () as budget_headroom_gbp_m,

    -- This position's share of the mandatory floor.
    cf.cheapest_fill_gbp_m / nullif(sum(cf.cheapest_fill_gbp_m) over (), 0) as share_of_minimum_squad

from supply as s
inner join cheapest_fill as cf on cf.position_id = s.position_id
inner join dearest_fill as df on df.position_id = s.position_id
cross join {{ ref('stg_fpl__game_settings') }} as gs

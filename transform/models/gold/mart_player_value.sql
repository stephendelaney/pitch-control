-- Is this player worth their price? One row per player, 568 of them.
--
-- Everything here is a ratio or a rank, which is the reason it is a mart and not a dimension:
-- none of it is a fact about the player, all of it is a fact about the player *relative to the
-- squad-building problem* — a fixed £100.0m budget, 15 slots, at most 3 from any one club
-- (ADR-0018, and those numbers come from `stg_fpl__game_settings`, not from a constant here).
-- Under a budget constraint, points per million is the quantity that actually decides a squad,
-- and raw points is a distraction.
--
-- ⚠️ **Right now these points are last season's, and nothing in FPL's payload says so.**
--
-- The obvious assumption about a pre-season lake is that the scoring columns are all zero, the
-- way `event_live` correctly loads no rows. They are not. Measured against the live lake:
-- **zero gameweeks are finished, and yet 400 of 568 players carry non-zero `total_points`, with
-- a maximum of 38 `starts` and 3,420 `minutes`** — a full 38-game season. FPL carries the
-- previous season's aggregates in `bootstrap-static` until it resets them, so `total_points`,
-- `minutes`, `points_per_game` and the whole contribution block currently describe 2025/26.
--
-- That is a worse trap than zeros, because zeros are obviously unusable and these numbers look
-- perfectly usable. And they are attached to the player's **current** club: Semenyo shows 3,200
-- minutes and 202 points against MCI, none of which he played there. Any team-level roll-up of
-- these columns is therefore wrong in a way that no test on this model can detect, because
-- every value is individually valid.
--
-- So the provenance is labelled rather than assumed: `points_are_prior_season` is derived from
-- the data — players have minutes while no gameweek has been played — not from FPL's flags or
-- from the calendar. That matters because FPL zeroes the totals at some unannounced moment
-- before GW1, and a rule based on "is it August" would be wrong for that window.
-- `assert_prior_season_points_are_flagged` holds it.
--
-- `form` is the one scoring column that is genuinely zero for all 568, and consistently so: it
-- is a 30-day rolling window (`form_window_days` in `stg_fpl__game_settings`), so it expires
-- rather than carries over. Which is itself the tell — a payload where `form` is empty but
-- `total_points` is not is a payload straddling two seasons.

{{ config(location = gold_location()) }}

with planning_gameweek as (

    -- The gameweek a manager is currently deciding for: the earliest one that is not finished.
    --
    -- Not `is_next` and not `is_current`, because neither is reliable on its own — all three of
    -- FPL's flags are false pre-season (which is the state of the lake today) and `is_current`
    -- is the one being *played*, not the one being picked. "First unfinished" is true in every
    -- phase of the season, including the last gameweek, where it is GW38 and stays there.
    select min(gameweek_id) as gameweek_id
    from {{ ref('stg_fpl__gameweeks') }}
    where not is_finished

),

points_provenance as (

    -- Whether the scoring columns describe last season or this one.
    --
    -- Derived from the data rather than from a flag or a date: a player cannot have logged
    -- minutes in a season whose first gameweek has not finished, so minutes-without-a-played-
    -- gameweek is proof the totals predate the season. FPL zeroes them at some unannounced
    -- point before GW1, and this rule follows that reset the moment it happens instead of
    -- guessing when it will.
    select
        (select count(*) from {{ ref('stg_fpl__gameweeks') }} where is_finished) = 0
        and (select max(minutes) from {{ ref('dim_player') }}) > 0 as points_are_prior_season

),

valued as (

    select
        p.player_id,
        p.player_code,
        p.display_name,
        p.team_id,
        p.team_short_name,
        p.team_name,
        p.position_id,
        p.position_short_name,
        p.position_name,

        p.now_cost_gbp_m,
        p.price_change_season_gbp_m,
        p.price_change_gameweek_gbp_m,

        p.status,
        p.is_available,
        p.is_pickable,
        p.chance_of_playing_next_round,

        -- ── scoring ─────────────────────────────────────────────────────────────────────
        -- Read `points_are_prior_season` before reading any of these. See the header: they
        -- currently describe 2025/26, attached to 2026/27 clubs.
        pp.points_are_prior_season,

        p.total_points,
        p.points_per_game,
        p.form,
        p.expected_points_next,
        p.minutes,
        p.starts,

        p.selected_by_percent,
        p.net_transfers_event,
        p.is_first_choice_penalties,

        -- ── value ratios ────────────────────────────────────────────────────────────────
        -- `nullif` on the denominator throughout. No player currently costs 0 (the floor is
        -- £3.8m) and none has 0 minutes once the season starts, but a ratio that returns
        -- infinity on bad input is a ratio that puts a broken row at the top of every ranking.
        p.total_points / nullif(p.now_cost_gbp_m, 0) as points_per_million,
        p.form / nullif(p.now_cost_gbp_m, 0) as form_per_million,
        p.expected_points_next / nullif(p.now_cost_gbp_m, 0) as expected_points_next_per_million,

        -- Per-90 separates "good" from "played a lot". A £4.5m defender who starts every week
        -- and a £12m forward rotated in for 20 minutes look nothing alike per 90 and can look
        -- similar on season totals.
        p.total_points * 90.0 / nullif(p.minutes, 0) as points_per_90,
        p.expected_goal_involvements_per_90,

        p.expected_goals,
        p.expected_assists,
        p.expected_goal_involvements,
        p.ict_index,
        p.bonus,
        p.bps,
        p.defensive_contribution,

        -- ── the fixture outlook ─────────────────────────────────────────────────────────
        -- Value tells you who has been worth their price; the fixture run tells you whether
        -- that is about to continue. Joined through the *team*, from `mart_team_fixture_run`
        -- at the planning gameweek, so a player inherits their club's next five.
        r.gameweek_id as planning_gameweek_id,
        r.next_{{ fixture_horizon() }}_fixture_count,
        r.next_{{ fixture_horizon() }}_avg_difficulty,
        r.next_{{ fixture_horizon() }}_home_count,
        r.next_{{ fixture_horizon() }}_is_partial,
        r.opponents as next_opponents,
        r.is_blank as is_blank_next_gameweek,
        r.is_double as is_double_next_gameweek

    from {{ ref('dim_player') }} as p
    cross join planning_gameweek as pg
    cross join points_provenance as pp
    left join {{ ref('mart_team_fixture_run') }} as r
        on r.team_id = p.team_id
        and r.gameweek_id = pg.gameweek_id

),

ranked as (

    select
        *,

        -- ── ranks ───────────────────────────────────────────────────────────────────────
        -- Within position is the one that matters: a squad needs exactly 2 goalkeepers and
        -- exactly 3 forwards (ADR-0018), so a goalkeeper competes with goalkeepers, never with
        -- the overall list. The overall rank is kept for the "best value in the game" question
        -- and nothing else.
        --
        -- `rank()`, not `row_number()`: ties are real and breaking them arbitrarily would
        -- invent an ordering. They are also common — 168 of 568 players have never scored a
        -- point, so they tie on every value ratio at once and deserve to share a rank rather
        -- than be silently sorted by player id.
        rank() over (order by points_per_million desc) as value_rank_overall,
        rank() over (
            partition by position_id order by points_per_million desc
        ) as value_rank_in_position,
        rank() over (
            partition by position_id order by form_per_million desc
        ) as form_value_rank_in_position,
        rank() over (
            partition by position_id order by now_cost_gbp_m desc
        ) as price_rank_in_position,
        rank() over (
            partition by position_id order by selected_by_percent desc
        ) as ownership_rank_in_position,

        percent_rank() over (
            partition by position_id order by points_per_million
        ) as value_percentile_in_position

    from valued

)

select
    *,

    -- ── differential ────────────────────────────────────────────────────────────────────
    -- A differential is a player who is good value and lightly owned: they gain rank against
    -- the field rather than just scoring points, because most rivals do not have them. The 5%
    -- ownership line is the conventional FPL threshold and the top-quartile value cut is ours.
    --
    -- This is a labelled opinion, not a fact, which is why it sits at the very end of the model
    -- with its inputs (`selected_by_percent`, `value_percentile_in_position`) exposed right
    -- beside it. Anyone who disagrees with the thresholds can rebuild it from the columns above
    -- instead of forking the mart.
    --
    -- While `points_are_prior_season` is true it reads "was good value last season and is
    -- lightly owned this one" — which is a real and useful pre-season signal, and not the
    -- thing the column name promises. 87 players qualify today.
    selected_by_percent < 5.0
        and value_percentile_in_position >= 0.75
        and is_pickable as is_differential

from ranked

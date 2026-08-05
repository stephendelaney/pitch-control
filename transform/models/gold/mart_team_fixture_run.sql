-- Fixture difficulty by team and gameweek, with a rolling {{ fixture_horizon() }}-gameweek
-- outlook. 20 teams x 38 gameweeks = 760 rows, always.
--
-- "Always" is the load-bearing word, and it is why this model starts with a cross join instead
-- of a group-by over `fct_team_fixture`.
--
-- A blank gameweek — a team with no fixture, because their match was moved for a cup tie — has
-- no row in the fixture table at all. Aggregate the fixtures directly and those (team,
-- gameweek) pairs simply do not appear, and then a window frame of "current row and 4
-- following" walks over *fixtures*, not gameweeks: a team with a blank in GW29 would have its
-- "next 5" quietly span GW28-33 while every other team's spans GW28-32. The numbers would be
-- comparable-looking and wrong, and nothing about the output would suggest it.
--
-- The cross join makes the grid complete first, so the frame counts gameweeks by construction
-- and a blank is a real row with `fixture_count = 0`. `assert_fixture_run_grid_is_complete`
-- holds that property, because it is the one assumption every window in this file rests on.
--
-- Double gameweeks are the mirror image: two fixtures collapse into one row, which is why
-- `fixture_count` is exposed and why the horizon carries both a total and an average (see the
-- note on the outlook block below).

{{ config(location = gold_location()) }}

with grid as (

    -- Every team, every gameweek. 760 rows before a single fixture is looked at.
    select
        t.team_id,
        t.team_name,
        t.team_short_name,
        g.gameweek_id,
        g.gameweek_name,
        g.deadline_time,
        g.is_finished as gameweek_is_finished,
        g.is_settled as gameweek_is_settled,
        g.is_current as gameweek_is_current,
        g.is_next as gameweek_is_next
    from {{ ref('dim_team') }} as t
    cross join {{ ref('stg_fpl__gameweeks') }} as g

),

per_gameweek as (

    -- Fixtures folded onto the grid. A fixture whose `gameweek_id` is null (FPL has not
    -- assigned it — a postponement awaiting a slot) joins to nothing and is excluded here by
    -- construction. That is correct: an unscheduled fixture is not in anyone's next five. It
    -- does mean `sum(fixture_count)` over this mart can be less than 760, so the count of
    -- scheduled fixtures is a property of the data, not an invariant to test.
    select
        grid.*,

        count(f.fixture_id) as fixture_count,
        count(f.fixture_id) = 0 as is_blank,
        count(f.fixture_id) > 1 as is_double,
        count(f.fixture_id) filter (where f.is_home) as home_fixture_count,

        -- Null on a blank, and deliberately so — a blank is *no* difficulty, not zero
        -- difficulty, and zero would sort as the easiest gameweek of the season.
        avg(f.difficulty) as avg_difficulty,
        sum(f.difficulty) as total_difficulty,
        min(f.difficulty) as easiest_difficulty,
        max(f.difficulty) as hardest_difficulty,

        -- Human-readable, for the dashboard column nobody wants to build by hand: "ARS (H),
        -- CHE (A)". Ordered by kickoff so a double gameweek reads in the order it is played.
        string_agg(
            opp.team_short_name || ' (' || f.venue || ')',
            ', ' order by f.kickoff_time
        ) as opponents

    from grid
    left join {{ ref('fct_team_fixture') }} as f
        on f.team_id = grid.team_id
        and f.gameweek_id = grid.gameweek_id
    left join {{ ref('dim_team') }} as opp
        on opp.team_id = f.opponent_team_id
    group by all

)

select
    team_id,
    team_name,
    team_short_name,

    gameweek_id,
    gameweek_name,
    deadline_time,
    gameweek_is_finished,
    gameweek_is_settled,
    gameweek_is_current,
    gameweek_is_next,

    -- ── this gameweek ───────────────────────────────────────────────────────────────────
    fixture_count,
    is_blank,
    is_double,
    home_fixture_count,
    avg_difficulty,
    total_difficulty,
    easiest_difficulty,
    hardest_difficulty,
    opponents,

    -- ── the {{ fixture_horizon() }}-gameweek outlook ────────────────────────────────────
    -- Both a total and an average, because neither alone is enough and the difference is the
    -- whole point of a fixture-run mart:
    --
    --   * the average is comparable across teams (it is per fixture) but is blind to how many
    --     fixtures there are — a blank gameweek looks like a free pass rather than a lost one;
    --   * the total is sensitive to fixture count but is not comparable on its own, because a
    --     team with a double gameweek accumulates more difficulty precisely by having more
    --     chances to score.
    --
    -- So `fixture_count` travels with them. A run of four easy fixtures beats five medium ones
    -- for a *bench*, and loses to it for a starting XI, and that is a judgement this layer
    -- should inform rather than make.
    --
    -- Cast back to `integer`: DuckDB widens `sum()` over a bigint to HUGEINT, Parquet has no
    -- 128-bit integer, and dbt-duckdb resolves that by writing the column as a double. A
    -- fixture count arriving in a dashboard as `5.0` is only cosmetic here, but the same
    -- silent int→float demotion is not cosmetic at all once a column is big enough to lose
    -- precision past 2^53. Pin the type where the widening happens.
    cast(sum(fixture_count) over horizon as integer) as next_{{ fixture_horizon() }}_fixture_count,
    cast(sum(total_difficulty) over horizon as integer) as next_{{ fixture_horizon() }}_total_difficulty,
    -- Recomputed from the sums rather than averaging the per-gameweek averages: an average of
    -- averages weights a single-fixture gameweek the same as a double.
    sum(total_difficulty) over horizon
        / nullif(sum(fixture_count) over horizon, 0) as next_{{ fixture_horizon() }}_avg_difficulty,
    cast(sum(home_fixture_count) over horizon as integer) as next_{{ fixture_horizon() }}_home_count,
    cast(count(*) over horizon as integer) as next_{{ fixture_horizon() }}_gameweeks_covered,

    -- True in the last {{ fixture_horizon() - 1 }} gameweeks of the season, where the window
    -- runs off the end and covers fewer than {{ fixture_horizon() }} gameweeks. The average
    -- stays comparable there; the totals do not.
    count(*) over horizon < {{ fixture_horizon() }} as next_{{ fixture_horizon() }}_is_partial

from per_gameweek
window horizon as (
    partition by team_id
    order by gameweek_id
    rows between current row and {{ fixture_horizon() - 1 }} following
)

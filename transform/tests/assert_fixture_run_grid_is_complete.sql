-- `mart_team_fixture_run` computes its rolling outlook with
-- `rows between current row and 4 following`, partitioned by team and ordered by gameweek.
--
-- A `rows` frame counts *rows*, not gameweeks. It only means "the next five gameweeks" if every
-- team has exactly one row per gameweek — which is true because the model cross joins teams to
-- gameweeks before it touches a fixture, and would stop being true the moment someone
-- "simplified" that into a group-by over `fct_team_fixture`.
--
-- That simplification looks correct and passes every other test. Blank gameweeks — a team with
-- no fixture, because their match was moved for a cup tie — would just be missing rows, and the
-- window would silently span six real gameweeks for that team and five for everyone else. Every
-- number would still be a plausible 1-5 difficulty average.
--
-- So the invariant is the grid itself: one row per (team, gameweek), no gaps, no duplicates.
-- Checked three ways because each catches a different mistake — a missing pair, a duplicated
-- pair, and a total that drifts even when neither of those shows up per-team.

with grid as (

    select
        count(*) as row_count,
        count(distinct (team_id, gameweek_id)) as pair_count,
        count(distinct team_id) as team_count,
        count(distinct gameweek_id) as gameweek_count
    from {{ ref('mart_team_fixture_run') }}

),

per_team as (

    select team_id, count(*) as gameweeks
    from {{ ref('mart_team_fixture_run') }}
    group by team_id

),

expected as (

    select
        (select count(*) from {{ ref('dim_team') }}) as teams,
        (select count(*) from {{ ref('stg_fpl__gameweeks') }}) as gameweeks

)

-- 1. no duplicated (team, gameweek) pairs, and the grid is the full product
select
    'grid_shape' as failure,
    g.row_count,
    g.pair_count,
    g.team_count,
    g.gameweek_count
from grid as g
cross join expected as e
where g.row_count <> g.pair_count
   or g.row_count <> e.teams * e.gameweeks
   or g.team_count <> e.teams
   or g.gameweek_count <> e.gameweeks

union all

-- 2. every team covers every gameweek — catches a gap that a coincidentally-correct total hides
select
    'team_coverage' as failure,
    t.gameweeks as row_count,
    t.gameweeks as pair_count,
    t.team_id as team_count,
    null as gameweek_count
from per_team as t
cross join expected as e
where t.gameweeks <> e.gameweeks

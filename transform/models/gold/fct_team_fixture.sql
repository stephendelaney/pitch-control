-- One row per team per fixture — the 380-match season seen twice, once from each dugout.
-- 760 rows.
--
-- This is the model that makes the rest of the fixture analysis possible, and it exists because
-- Silver's `stg_fpl__fixtures` has the wrong grain for almost every question anyone asks of it.
-- A fixture row is two-sided: `team_h` / `team_a`, `team_h_difficulty` / `team_a_difficulty`,
-- `team_h_score` / `team_a_score`. Any question phrased "for a given team…" — their next five,
-- their home record, their difficulty run — has to reach into both halves and pick a side, and
-- every consumer that does it re-implements the same `case when team_h = ? then ... else ...`
-- ladder. Get one branch wrong and the number is subtly, silently wrong for half the league.
--
-- Unpivoting to (team, fixture) makes all of those a plain `where team_id = ?` and a plain
-- aggregate. The cost is stating the mapping twice, once per side of the union — which is
-- exactly the thing `assert_fixture_sides_balance` checks, because a copy-paste slip in the
-- second branch is the obvious way this model goes wrong.
--
-- Note what is *not* here: no `event_live`, so no player-level match stats. `stats_json` on the
-- Silver fixture carries the per-match breakdown as text and unpacking it invents a
-- player-per-fixture grain that this model does not have. That lands with the first played
-- gameweek (ADR-0017).

{{ config(location = gold_location()) }}

with sides as (

    select
        fixture_id,
        fixture_code,
        gameweek_id,
        kickoff_time,
        is_provisional_start,
        is_started,
        is_finished,
        minutes_played,

        home_team_id as team_id,
        away_team_id as opponent_team_id,
        true as is_home,
        home_team_difficulty as difficulty,
        away_team_difficulty as opponent_difficulty,
        home_score as goals_for,
        away_score as goals_against

    from {{ ref('stg_fpl__fixtures') }}

    union all

    select
        fixture_id,
        fixture_code,
        gameweek_id,
        kickoff_time,
        is_provisional_start,
        is_started,
        is_finished,
        minutes_played,

        away_team_id as team_id,
        home_team_id as opponent_team_id,
        false as is_home,
        away_team_difficulty as difficulty,
        home_team_difficulty as opponent_difficulty,
        away_score as goals_for,
        home_score as goals_against

    from {{ ref('stg_fpl__fixtures') }}

)

select
    s.fixture_id,
    s.fixture_code,

    -- Nullable, inherited from Silver: FPL leaves it null for a fixture not yet assigned to a
    -- gameweek. Populated for all 380 today, but a postponement in November will null one out,
    -- and `mart_team_fixture_run` has to survive that.
    s.gameweek_id,

    s.team_id,
    s.opponent_team_id,
    s.is_home,
    case when s.is_home then 'H' else 'A' end as venue,

    s.kickoff_time,
    s.is_provisional_start,

    -- ── difficulty ──────────────────────────────────────────────────────────────────────
    -- FPL's 1-5, already from this team's point of view — `team_h_difficulty` is how hard the
    -- fixture is *for the home team*, not how good the home team is. Getting that backwards
    -- inverts every fixture-run ranking in the project, which is why it is stated here once.
    s.difficulty,
    s.opponent_difficulty,
    -- The opponent's rating minus ours: positive means we are the stronger side by FPL's own
    -- reckoning. Cheaper to read than comparing two 1-5 scales in your head.
    s.opponent_difficulty - s.difficulty as difficulty_edge,

    -- ── result ──────────────────────────────────────────────────────────────────────────
    -- Null for every row today. `home_score` / `away_score` are the split-null-rule columns
    -- (absent from Bronze entirely until the first match is played, surfaced by Silver as typed
    -- NULLs), so this whole block is correctly null pre-season and starts populating on
    -- matchday one without a schema change anywhere.
    s.goals_for,
    s.goals_against,
    s.goals_for - s.goals_against as goal_difference,

    -- Gated on `is_finished` rather than on the scores being non-null: a 0-0 that is still in
    -- progress has real scores and no result yet.
    case
        when not s.is_finished then null
        when s.goals_for > s.goals_against then 'W'
        when s.goals_for = s.goals_against then 'D'
        else 'L'
    end as result,

    case
        when not s.is_finished then null
        when s.goals_for > s.goals_against then 3
        when s.goals_for = s.goals_against then 1
        else 0
    end as league_points_won,

    s.is_started,
    s.is_finished,
    s.minutes_played

from sides as s

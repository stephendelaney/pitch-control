-- `fct_team_fixture` states the home→team mapping and the away→team mapping in two separate
-- branches of a UNION ALL. Duplicating a column list is how that model gets written, and
-- mis-copying one line of the second branch — `home_team_difficulty` where `away_team_difficulty`
-- belongs, `home_score` left in place — is how it gets written wrong.
--
-- Every one of those slips is invisible: the row count stays 760, every key is populated, every
-- schema test passes, and half the league quietly carries the other side's numbers. Only the
-- symmetry catches it.
--
-- Three properties, one per union'd fixture:
--
--   1. exactly two rows, one home and one away;
--   2. each side's `team_id` is the other side's `opponent_team_id` — the branches disagree
--      about who is playing whom if this fails;
--   3. each side's `difficulty` is the other side's `opponent_difficulty`, and the same for
--      goals — which is the property that catches a mis-copied column while the ids stay right.
--
-- Property 3 is checked with `is not distinct from`, not `=`, because goals are NULL for every
-- fixture until the season starts and `null = null` is not true. A plain equality would make
-- this test silently vacuous for the whole of pre-season — passing without checking anything,
-- which is the failure mode a test must never have.

with sides as (

    select
        fixture_id,
        count(*) as side_count,
        count(*) filter (where is_home) as home_count,
        count(*) filter (where not is_home) as away_count,

        max(team_id) filter (where is_home) as home_team,
        max(team_id) filter (where not is_home) as away_team,
        max(opponent_team_id) filter (where is_home) as home_opponent,
        max(opponent_team_id) filter (where not is_home) as away_opponent,

        max(difficulty) filter (where is_home) as home_difficulty,
        max(difficulty) filter (where not is_home) as away_difficulty,
        max(opponent_difficulty) filter (where is_home) as home_opponent_difficulty,
        max(opponent_difficulty) filter (where not is_home) as away_opponent_difficulty,

        max(goals_for) filter (where is_home) as home_goals_for,
        max(goals_against) filter (where not is_home) as away_goals_against

    from {{ ref('fct_team_fixture') }}
    group by fixture_id

)

select *
from sides
where
    -- 1. two rows, one per side
    side_count <> 2
    or home_count <> 1
    or away_count <> 1

    -- 2. the sides agree on who is playing whom
    or home_opponent <> away_team
    or away_opponent <> home_team

    -- 3. the sides agree on the numbers
    or home_difficulty is distinct from away_opponent_difficulty
    or away_difficulty is distinct from home_opponent_difficulty
    or home_goals_for is distinct from away_goals_against

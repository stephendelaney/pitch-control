-- The 380-match season. Re-snapshotted every run, because kickoff times move, difficulty
-- ratings are re-rated, and scores only exist once a match is played.
--
-- This model is where the split null rule bites hardest today: `team_h_score` and
-- `team_a_score` are null for every fixture in the lake right now (nothing has been played),
-- so Bronze has no such columns at all. Written naively — `select team_h_score` — this model
-- would not compile. Written defensively by dropping them, Silver's schema would silently gain
-- two columns on the first matchday and every consumer would have to cope. `optional_column`
-- takes the third path: the columns exist, typed, holding NULL, and nothing moves in August.

{% set available = bronze_columns(source('bronze_fpl', 'fixtures')) %}

with snapshot as (

    select *
    from {{ source('bronze_fpl', 'fixtures') }}
    where _dlt_load_id = ({{ latest_completed_load() }})

)

select
    id as fixture_id,
    code as fixture_code,

    -- Null for a fixture not yet assigned to a gameweek (postponements, TV reshuffles), so
    -- this FK is deliberately nullable — see the relationships test in _silver__models.yml.
    event as gameweek_id,

    kickoff_time,
    provisional_start_time as is_provisional_start,

    team_h as home_team_id,
    team_a as away_team_id,

    {{ optional_column(available, 'team_h_score', 'bigint', alias='home_score') }},
    {{ optional_column(available, 'team_a_score', 'bigint', alias='away_score') }},

    -- FPL's 1-5 fixture difficulty, from each side's point of view.
    team_h_difficulty as home_team_difficulty,
    team_a_difficulty as away_team_difficulty,

    started as is_started,
    finished as is_finished,
    finished_provisional as is_finished_provisional,
    minutes as minutes_played,

    -- Per-match stat breakdown (goals, assists, bonus, …) as JSON text. Same reasoning as
    -- `chip_plays_json`: exploding it invents a grain, and that is a Gold decision.
    cast(stats as varchar) as stats_json,

    pulse_id,

    _dlt_load_id as load_id

from snapshot

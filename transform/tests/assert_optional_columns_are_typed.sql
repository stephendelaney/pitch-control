-- The split null rule, asserted against the thing that can silently regress.
--
-- `optional_column` (macros/bronze.sql) exists so that a Bronze column which is null for every
-- row — and therefore absent from the JSONL entirely — still appears in Silver as a typed NULL.
-- The failure mode it prevents is not an error. It is someone hitting "column not found",
-- deleting the column from the model, and Silver quietly growing two columns on the first
-- matchday while every downstream consumer's schema assumption breaks.
--
-- Two things could regress and neither would fail the build on its own:
--   * the column is dropped from the model      → this test fails to compile, loudly
--   * the column is kept but loses its cast     → `typeof` catches it here
--
-- The type matters as much as the presence: an untyped `null` is INTEGER in DuckDB, so a
-- forgotten cast would write a Parquet column of the wrong type that only breaks when real
-- values arrive and the file schemas stop matching across partitions.
--
-- Returns any column whose type has drifted. Empty result = pass.

with checks as (

    select * from (
        select
            'stg_fpl__fixtures.home_score' as column_ref,
            typeof(home_score) as actual_type,
            'BIGINT' as expected_type
        from {{ ref('stg_fpl__fixtures') }}
        limit 1
    )

    union all

    select * from (
        select
            'stg_fpl__fixtures.away_score',
            typeof(away_score),
            'BIGINT'
        from {{ ref('stg_fpl__fixtures') }}
        limit 1
    )

    union all

    select * from (
        select
            'stg_fpl__players.expected_points_this',
            typeof(expected_points_this),
            'DOUBLE'
        from {{ ref('stg_fpl__players') }}
        limit 1
    )

    union all

    select * from (
        select
            'stg_fpl__players.chance_of_playing_this_round',
            typeof(chance_of_playing_this_round),
            'BIGINT'
        from {{ ref('stg_fpl__players') }}
        limit 1
    )

)

select
    column_ref,
    actual_type,
    expected_type
from checks
where actual_type <> expected_type

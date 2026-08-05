-- The snapshot rule, asserted rather than trusted.
--
-- `latest_completed_load()` is called independently by every staging model. Nothing in dbt
-- forces those calls to agree, and they are evaluated against the lake at run time — so a load
-- that commits *while a build is in flight* would give some models the old snapshot and others
-- the new one. The result is a Silver layer that is internally inconsistent (a player
-- referencing a team_id that the teams model does not have yet) without any single model
-- looking wrong. That is the failure this test exists for; it is a race, so it will not
-- reproduce on demand, which is exactly why it needs a test rather than an eyeball.
--
-- Three conditions, all of which must hold:
--   1. each model drew from exactly one load
--   2. every model drew from the *same* load
--   3. that load is committed in dlt's ledger (never a half-written run)
--
-- Returns the offending models. Empty result = pass.

with load_ids as (

    select 'stg_fpl__teams' as model_name, load_id from {{ ref('stg_fpl__teams') }}
    union all
    select 'stg_fpl__positions', load_id from {{ ref('stg_fpl__positions') }}
    union all
    select 'stg_fpl__gameweeks', load_id from {{ ref('stg_fpl__gameweeks') }}
    union all
    select 'stg_fpl__fixtures', load_id from {{ ref('stg_fpl__fixtures') }}
    union all
    select 'stg_fpl__players', load_id from {{ ref('stg_fpl__players') }}
    union all
    select 'stg_fpl__chips', load_id from {{ ref('stg_fpl__chips') }}
    union all
    select 'stg_fpl__phases', load_id from {{ ref('stg_fpl__phases') }}
    union all
    select 'stg_fpl__stat_types', load_id from {{ ref('stg_fpl__stat_types') }}
    union all
    select 'stg_fpl__game_settings', load_id from {{ ref('stg_fpl__game_settings') }}

),

per_model as (

    select
        model_name,
        count(distinct load_id) as distinct_loads,
        min(load_id) as load_id
    from load_ids
    group by 1

),

committed_loads as (

    select load_id
    from {{ ref('stg_fpl__loads') }}
    where is_committed

)

select
    model_name,
    distinct_loads,
    load_id
from per_model
where
    distinct_loads <> 1
    or load_id not in (select load_id from committed_loads)
    or (select count(distinct load_id) from per_model) <> 1

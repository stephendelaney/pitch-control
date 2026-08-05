{#
  Project-local generic tests.

  Only what is actually used, and only what dbt-core does not already ship.
#}


{% test unique_combination_of_columns(model, combination_of_columns) %}
    {#-
      Composite uniqueness. dbt-core's built-in `unique` is single-column, and a Gold fact whose
      grain is a pair — (fixture_id, team_id) — has no single column that is unique by
      definition: `fixture_id` appears twice on purpose.

      This is deliberately name-compatible with `dbt_utils.unique_combination_of_columns`, so
      swapping to the package later is a one-line change per test rather than a rewrite. It is
      local rather than a `packages.yml` entry because dbt_utils would be the project's first
      dbt dependency, and pulling ~40 macros plus a `dbt deps` step and a hub fetch in CI to get
      one twelve-line test is not a trade worth making yet. When a second or third dbt_utils
      test is genuinely wanted, take the package and delete this file.
    -#}
    {%- set columns = combination_of_columns | join(', ') -%}

    select
        {{ columns }},
        count(*) as duplicate_count
    from {{ model }}
    group by {{ columns }}
    having count(*) > 1

{% endtest %}

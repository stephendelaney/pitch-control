{#
  Helpers for reading Bronze. Three macros, each one encoding a rule from the Bronze contract
  (`ingest/README.md`) that would otherwise live in a comment and be got wrong once per model.

  ADR-0005 says keep models flat and lean on ref()/tests over cleverness, so this file is
  deliberately small: no model-generating macros, nothing that hides a join. Each macro emits
  a fragment you can read in the compiled SQL.
#}


{% macro latest_completed_load() -%}
    {#-
      The load_id of the newest *committed* FPL load.

      Bronze is append-only: every run appends a full re-snapshot, so the same player appears
      once per load. Silver has to reduce that to one row per key, and there are two defensible
      rules:

        (a) latest observation per key — `row_number() over (partition by id ...)`
        (b) the latest complete snapshot — every row from one load_id

      We take (b). Under (a), an entity that FPL *removes* keeps its last observation forever,
      so Silver silently accumulates ghosts that no longer exist upstream and nothing ever
      surfaces it. Under (b), a disappearance shows up honestly as a row-count change. This is
      not hypothetical here: the player count has moved 564 → 567 → 568 across the first six
      loads while FPL adds players pre-season.

      The price of (b) is that a partial load would truncate Silver — which is exactly why the
      load_id comes from dlt's `_dlt_loads` ledger filtered to `status = 0` (committed), rather
      than from `max(load_date)` over the data files. A run that died mid-write leaves data
      files behind but never gets its ledger row, so it can never be selected as the snapshot.

      Ordering is on the numeric value, not the string. load_ids are epoch seconds as text
      ('1785871942.6436524'), so lexicographic ordering agrees with time only while the integer
      part keeps the same digit count — true until 2286, but true by accident. The comparison
      downstream is still string equality against the exact value returned here, so nothing
      depends on float round-tripping.
    -#}
    select load_id
    from {{ source('bronze_fpl', 'dlt_loads') }}
    where status = 0
    order by cast(load_id as double) desc
    limit 1
{%- endmacro %}


{% macro bronze_columns(relation) -%}
    {#-
      The columns that actually exist in a Bronze relation, lowercased.

      Probed with a `limit 0` query at compile time rather than
      `adapter.get_columns_in_relation`, because a Bronze source is not a table — it renders as
      a `read_json(...)` call, which has no information_schema entry to look up.

      Costs one trivial query per model that asks. Returns [] during parsing, when there is no
      connection yet; `optional_column` treats that as "absent", which is the safe direction —
      it emits a typed NULL and the model still parses.
    -#}
    {%- if not execute -%}
        {{ return([]) }}
    {%- endif -%}
    {%- set probe = run_query("select * from " ~ relation ~ " limit 0") -%}
    {{ return(probe.column_names | map('lower') | list) }}
{%- endmacro %}


{% macro optional_column(available, column_name, data_type, alias=none) -%}
    {#-
      Select a Bronze column that may not exist, as a typed NULL when it does not.

      This is the split null rule's first half, implemented rather than documented:

        > a column that is NULL for every row is absent from the file entirely, so Silver must
        > treat a missing column as null rather than assume presence.

      `union_by_name=true` on the source (see models/sources.yml) already handles a column that
      is missing from *some* loads. It cannot help with a column missing from *all* of them —
      there the model simply fails to compile with "column not found", and the tempting fix is
      to delete the column from Silver, which quietly changes the schema every downstream
      consumer reads.

      Live examples, all four genuinely absent from every file in the lake right now because
      pre-season makes them null for every row: `fixtures.team_h_score`, `team_a_score`,
      `elements.ep_this`, `elements.chance_of_playing_this_round`. Every one of them appears the
      moment the season starts. Silver's column list must not move when they do.

      The rule's *other* half is deliberately not implemented here, because it is the opposite
      rule: a `null` inside a JSONB payload is preserved, so a missing key inside a payload is
      meaningful and must not be read as null. That half applies to `bronze/postgres/`, which
      has no data yet — see models/sources.yml.
    -#}
    {%- set output_name = alias if alias else column_name -%}
    {%- if column_name | lower in available -%}
        cast({{ adapter.quote(column_name) }} as {{ data_type }}) as {{ adapter.quote(output_name) }}
    {%- else -%}
        cast(null as {{ data_type }}) as {{ adapter.quote(output_name) }}
    {%- endif -%}
{%- endmacro %}

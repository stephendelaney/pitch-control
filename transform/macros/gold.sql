{#
  Helpers for writing Gold.

  Same posture as macros/bronze.sql: small, readable, and each macro encodes one rule that
  would otherwise be a comment got wrong once per model.
#}


{% macro gold_location() -%}
    {#-
      Where a Gold model's Parquet lands.

      profiles.yml's `external_root` is a single value per target and points at `silver/`, so
      Gold has to say where it goes. This macro is called from each model's own
      `{{ config(location=...) }}` header rather than from a `+location` in dbt_project.yml,
      and that is forced rather than chosen: dbt renders dbt_project.yml at project load, before
      user macros are registered (it fails with `'gold_location' is undefined`) and with no
      `this` in scope to name the file — so a project-level setting would put every Gold model
      at the same path even if the macro did resolve.

      The lake/local switch is the same one profiles.yml and the ingest layer use, with the same
      semantics: PITCH_CONTROL_LAKE_BUCKET set means S3, unset means local disk. Duplicating the
      expression rather than reading `external_root` and rewriting `silver` → `gold` is
      deliberate — a string replace on a path is the kind of thing that keeps working until a
      bucket is named something with "silver" in it.

      NB: DuckDB writes files but does not create directories, so local runs need
      `mkdir -p _local_gold` first. S3 has no such problem.
    -#}
    {{- ('s3://' ~ env_var('PITCH_CONTROL_LAKE_BUCKET') ~ '/gold'
         if env_var('PITCH_CONTROL_LAKE_BUCKET', '')
         else '_local_gold') ~ '/' ~ this.identifier ~ '.parquet' -}}
{%- endmacro %}


{% macro fixture_horizon() -%}
    {#-
      How many gameweeks ahead the fixture-difficulty outlook covers.

      Five is the conventional FPL planning window — long enough that a run of easy fixtures is
      a real signal, short enough that FPL has actually scheduled the kickoffs. It is defined
      once here because it appears in a window frame *and* in the column names that describe it
      (`next_5_...`), and those two silently disagreeing is a bug nothing would catch.

      Returned as an int rather than emitted as text, so the caller can do arithmetic on it —
      the window frame needs `horizon - 1`, since a frame of "current row and N-1 following"
      spans N gameweeks.
    -#}
    {{- return(5) -}}
{%- endmacro %}

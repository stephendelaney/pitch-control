-- Global game state and rules — one row, always.
--
-- This model earns its place by pinning down the numbers ADR-0018 says we mirror rather than
-- invent. `docs/product/game-design.md` §5 documents a squad size of 15, a 3-per-club limit and
-- a £100.0m budget; those are FPL's values, and this is where they arrive as *data* instead of
-- constants copied into a spec that can drift from the source without anyone noticing.
--
-- The nested config is flattened only where a field is a rule we depend on. The rest stays as
-- JSON text: the scoring block in particular is ADR-0017's oracle and is worth keeping whole
-- and faithful rather than pinning to a column list that FPL changes between seasons.

with snapshot as (

    select *
    from {{ source('bronze_fpl', 'game_meta') }}
    where _dlt_load_id = ({{ latest_completed_load() }})

)

select
    total_players,

    -- ── squad rules (game-design §5) ────────────────────────────────────────────────────
    (game_settings).squad_squadsize as squad_size,
    (game_settings).squad_squadplay as lineup_size,
    (game_settings).squad_team_limit as max_players_per_club,
    -- In tenths of a million, same convention as player price.
    (game_settings).squad_total_spend as budget_tenths,
    (game_settings).squad_total_spend / 10.0 as budget_gbp_m,

    -- ── transfer & economy rules (ADR-0018) ─────────────────────────────────────────────
    (game_settings).transfers_cap as transfers_cap,
    (game_settings).max_extra_free_transfers as max_extra_free_transfers,
    (game_settings).transfers_sell_on_fee as sell_on_fee,
    (game_settings).element_sell_at_purchase_price as sells_at_purchase_price,

    -- ── league rules ────────────────────────────────────────────────────────────────────
    (game_settings).league_points_h2h_win as h2h_points_win,
    (game_settings).league_points_h2h_draw as h2h_points_draw,
    (game_settings).league_points_h2h_lose as h2h_points_loss,
    (game_settings).league_join_private_max as max_private_leagues,
    (game_settings).league_join_public_max as max_public_leagues,

    -- ── misc ────────────────────────────────────────────────────────────────────────────
    (game_settings).stats_form_days as form_window_days,
    (game_settings).ui_currency_multiplier as currency_multiplier,
    (game_settings).timezone as game_timezone,

    -- ── kept whole ──────────────────────────────────────────────────────────────────────
    -- ADR-0017's scoring oracle: what each stat is worth, by position. Flattening it would
    -- mean a column per stat per position and a schema change whenever FPL adds a scoring
    -- category (they added defensive contribution this season).
    cast((game_config).scoring as varchar) as scoring_config_json,
    cast(game_settings as varchar) as game_settings_json,

    _dlt_load_id as load_id

from snapshot

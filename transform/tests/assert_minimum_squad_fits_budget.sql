-- The game is only playable if a legal squad can be bought.
--
-- FPL forces exactly 2 GKP / 5 DEF / 5 MID / 3 FWD (ADR-0018) inside a £100.0m budget. Take the
-- `squad_required` cheapest buyable players in every position and you get the floor: the least
-- any valid squad can possibly cost. If that floor ever exceeds the budget, no squad can be
-- built, and the game's own rules contradict each other.
--
-- It is not an idle check. Both sides of the comparison move independently and neither is ours:
-- prices rise all season as players are transferred in, the cheap end of the pool thins out as
-- FPL removes players who have left the league, and the budget is a value FPL publishes in
-- `game_settings` and could change between seasons. ADR-0018 says we *mirror* FPL rather than
-- invent, so the moment those drift into contradiction this build should fail rather than
-- publish a mart describing an unplayable game.
--
-- Two things are checked, and the second is the one that will actually fire first:
--
--   1. the floor fits inside the budget at all — a hard contradiction;
--   2. it leaves a sane amount of headroom. A floor consuming more than 85% of the budget means
--      the game has stopped being a selection problem and become an arithmetic one, long before
--      it becomes literally impossible. Today the floor is around 60% and the headroom is what
--      makes the game interesting, so this is a wide, quiet band — not a tripwire on drift.
--
-- Also asserts the mart's own arithmetic: `budget_headroom_gbp_m` must equal budget minus floor.
-- That column is what a dashboard reads, and a window function computed over the wrong frame
-- would give a per-position number that still looks like money.

with squad as (

    select
        max(minimum_squad_gbp_m) as minimum_squad_gbp_m,
        max(budget_gbp_m) as budget_gbp_m,
        max(budget_headroom_gbp_m) as headroom_gbp_m,
        sum(cheapest_fill_gbp_m) as summed_fill_gbp_m,
        sum(squad_required) as squad_slots,
        max(squad_size) as squad_size
    from {{ ref('mart_position_scarcity') }}

)

select
    minimum_squad_gbp_m,
    budget_gbp_m,
    headroom_gbp_m,
    squad_slots,
    squad_size
from squad
where
    -- 1. a legal squad is buyable
    minimum_squad_gbp_m > budget_gbp_m

    -- 2. and buyable with room to make choices
    or minimum_squad_gbp_m > budget_gbp_m * 0.85

    -- the window sum is over the four position rows, nothing more and nothing less
    or abs(minimum_squad_gbp_m - summed_fill_gbp_m) > 0.001
    or abs(headroom_gbp_m - (budget_gbp_m - minimum_squad_gbp_m)) > 0.001

    -- and the per-position requirements still add up to the squad size FPL states separately
    -- (the same two-sources-of-truth problem `assert_squad_rules_agree` guards in Silver,
    -- re-checked here because this model does arithmetic with both)
    or squad_slots <> squad_size

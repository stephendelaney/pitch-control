# Game Design & Mechanics

> The rules of the football-manager game. This is a **living product spec** (it evolves as we
> playtest), not an immutable ADR — but the genuinely either/or choices inside it are promoted to
> ADRs (flagged inline). Status: **v1 mechanics reviewed & agreed** (Stephen, 2026-06-19) — remains a
> living draft that evolves with playtesting; defines intended mechanics, not built state.

## Why this document exists

The engineering scaffolding (Medallion lake, CDP, SLOs, ADRs) was specified before the game itself.
That was deliberate — discipline first — but it left the **mechanics underspecified**. This doc
closes that gap. Crucially, every rule here is also a **data-generation decision**: each mechanic
defines what gets written to the OLTP system of record and what behavioral event flows to the CDP.
The game is the *fun surface*; its real job is to emit realistic, joinable data (see
[`../architecture/system-architecture.md`](../architecture/system-architecture.md)).

**Design principle: lean on FPL conventions.** Since the Fantasy Premier League API (ADR-0011) is the
primary data source, mirroring FPL's squad rules, prices, and scoring means our reference data,
player pool, and prices are *real and free* — no invented economy to balance. We simplify only where
it reduces build cost without hurting the data we want to study.

---

## 1. Core concept

A user — a **Manager** — runs a fantasy squad of **real Premier League players**. Across a 38-gameweek
season they buy/sell players within a budget, pick a starting XI each gameweek, and score points
driven by those players' **real-world performance**. Managers compete in **leagues** ranked by
cumulative points.

---

## 2. Squad construction

| Rule | Value | Source |
|---|---|---|
| Starting budget | **£100.0m** | FPL convention |
| Squad size | **15 players** | FPL |
| Positional quota | **2 GK · 5 DEF · 5 MID · 3 FWD** | FPL |
| Max per real club | **3 players** | FPL |
| Player prices | Ingested from FPL; fluctuate over the season | ADR-0011, `fct_price_changes` |

A squad is only valid when all four constraints hold simultaneously. Validation lives in the API
service layer (ADR-0015).

---

## 3. The gameweek lineup

Each gameweek the manager selects a **starting XI** (11 of the 15) plus a captain.

| Rule | Value |
|---|---|
| Goalkeepers | exactly **1** |
| Defenders | **3–5** |
| Midfielders | **2–5** |
| Forwards | **1–3** |
| Total starters | **11** |
| Captain | 1 player — **scores 2×** |
| Vice-captain | 1 player — captain's fallback if the captain doesn't play |
| Bench | the remaining 4 (1 GK + 3 outfield), **ordered** for auto-substitution |

**Auto-subs:** if a starter records 0 minutes, the first eligible bench player (in bench order) who
played is substituted in, provided formation constraints still hold. This mirrors FPL and keeps the
game forgiving for casual managers.

**Deadline:** lineups lock at the gameweek deadline (FPL's published deadline). Changes after lock
apply to the *next* gameweek.

---

## 4. Scoring

Points are computed per player per gameweek from real match stats. Baseline model (FPL standard):

| Action | GK | DEF | MID | FWD |
|---|---|---|---|---|
| Played 1–59 min | +1 | +1 | +1 | +1 |
| Played 60+ min | +2 | +2 | +2 | +2 |
| Goal scored | +6 | +6 | +5 | +4 |
| Assist | +3 | +3 | +3 | +3 |
| Clean sheet | +4 | +4 | +1 | — |
| Every 3 saves (GK) | +1 | — | — | — |
| Penalty save | +5 | — | — | — |
| Penalty miss | −2 | −2 | −2 | −2 |
| Every 2 goals conceded | −1 | −1 | — | — |
| Yellow card | −1 | −1 | −1 | −1 |
| Red card | −3 | −3 | −3 | −3 |
| Own goal | −2 | −2 | −2 | −2 |
| Bonus (BPS top performers) | +1…+3 | +1…+3 | +1…+3 | +1…+3 |

A manager's gameweek score = sum of starting XI points (captain doubled), after auto-subs, minus any
transfer penalties (§5).

> **⚠️ ADR-0017 (Scoring source) — decision needed.** Two ways to get these numbers:
> **(a) ingest FPL's already-computed `event_points` per player** and just attribute them to lineups
> (trivial, guaranteed-correct, but we don't *own* the logic); or **(b) compute points ourselves**
> from raw match stats (more code + a correctness SLI to defend, but a richer engineering surface and
> the only option if we ever diverge from FPL's rules). Recommendation: **start with (a)** for
> correctness-by-construction, keep (b) as a learning stretch. To be ratified in ADR-0017.

---

## 5. Transfers & the in-game economy

This is the primary generator of **business/OLTP** data (`fct_transfers`).

| Rule | Value |
|---|---|
| Free transfers | **1 per gameweek**, bankable up to **2** |
| Extra transfers | allowed, but **−4 points each** |
| Buy price | current FPL price |
| Sell price | purchase price, adjusted for price changes since (FPL sell-price rule: half of any rise, rounded down) |
| Budget | sells credit the bank; buys debit it; a transfer is only valid if the bank stays ≥ £0 |

Price changes are themselves ingested data (`fct_price_changes`), so the market moves on its own
between gameweeks — managers react to real price dynamics.

> **⚠️ ADR-0018 (Transfer & economy model) — decision needed.** The sell-price/banking/penalty rules
> are a balance decision. We can mirror FPL exactly, or simplify (e.g. sell at current price, no
> half-rise rule) to cut complexity. The chosen rules shape how `fct_transfers` looks and how
> interesting the "transfer behavior vs performance" analysis is. To be ratified in ADR-0018.

---

## 6. Chips / power-ups *(Phase 2 — optional)*

FPL-style one-shot chips add strategic depth and produce rich, sparse event data (great for cohort
analysis). Deferred until the core loop works.

| Chip | Effect | Uses/season |
|---|---|---|
| Wildcard | Unlimited transfers, no points hit, one gameweek | 2 |
| Free Hit | Unlimited transfers for one gameweek, squad reverts after | 1 |
| Bench Boost | Bench players also score that gameweek | 1 |
| Triple Captain | Captain scores 3× instead of 2× | 1 |

---

## 7. Leagues & competition

- A **season** = **38 gameweeks** (Premier League calendar).
- **Classic leagues:** managers ranked by **cumulative season points**. Join via invite code.
- **Head-to-head leagues** *(optional, Phase 2):* weekly 1-v-1 fixtures, 3 pts win / 1 draw.
- A league is a **league group** in the business domain and maps to a **PostHog cohort** in the CDP —
  this is where competition and engagement analysis meet (ADR-0013, `mart_manager_360`).

---

## 8. What each mechanic generates (the real payoff)

The reason the mechanics matter: each one defines concrete rows in the OLTP store **and** a behavioral
event in the CDP. This dual emission is what makes identity stitching (ADR-0013) worth doing.

| Manager action | Business/OLTP write (Postgres → Bronze) | CDP event (PostHog) |
|---|---|---|
| Create account / squad | `dim_user`, initial squad rows | `signup`, `squad_created` |
| Buy / sell player | `fct_transfers` (in/out, fee, bank) | `transfer_made` (player, price, gw) |
| Set lineup / captain | lineup snapshot per gameweek | `lineup_set`, `captain_changed` |
| Use a chip | chip-usage row | `chip_played` (type, gw) |
| Gameweek resolves | `fct_gameweek_scores` | `gameweek_viewed` (score, rank) |
| Join a league | `league_groups` membership | `league_joined` (cohort) |

These feed the headline Gold marts: `mart_manager_360` (who they are + what they did + how they
behaved) and `mart_engagement_vs_performance` (does behavior predict success/retention?).

---

## 9. Deliberately out of scope (for now)

To keep the free-tier, solo build tractable:

- No real-money anything; the £-budget is purely in-game.
- No live in-match scoring; points settle after the gameweek completes (batch, matches our ETL cadence).
- No mobile app; web SPA only (ADR-0014).
- Chips and head-to-head leagues are Phase 2.

---

## 10. Open decisions (promoted to ADRs)

| ADR | Decision | Why it matters |
|---|---|---|
| **0017** | Scoring source — ingest FPL `event_points` vs compute ourselves | Correctness model + how much logic we own (§4) |
| **0018** | Transfer & economy model — mirror FPL vs simplify | Shape of `fct_transfers`; richness of behavioral analysis (§5) |

Until these are ratified, treat §4–§5 as the **recommended defaults** (mirror FPL), not final.

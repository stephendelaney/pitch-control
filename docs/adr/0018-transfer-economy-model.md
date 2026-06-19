# ADR-0018: Transfer & economy model — mirror FPL vs simplify

- **Status:** Accepted
- **Date:** 2026-06-18
- **Deciders:** Stephen Delaney
- **Tags:** data-platform, game-mechanics, economy, oltp

## Context

The transfer market is the **primary generator of business/OLTP data** (`fct_transfers`) and the raw
material for the headline behavioural analysis — *does transfer behaviour predict performance and
retention?* (`mart_engagement_vs_performance`, ADR-0013). How rich and realistic that analysis can be
is determined by the rules we choose here. See [`../product/game-design.md`](../product/game-design.md)
§5 for the proposed rule set.

The choice is **how faithfully to mirror FPL's economy**:

- **Mirror FPL:** 1 free transfer per gameweek, bankable up to 2; extra transfers cost **−4 points**
  each; buy at current FPL price; **sell price = purchase price with gains halved** (rounded down to
  £0.1m) and falls taken in full; a transfer is valid only if the bank stays ≥ £0.
- **Simplify:** e.g. sell at current price (drop the half-rise rule), unlimited or free transfers,
  no point penalties — cheaper to build and validate.

Forces / constraints:
- **Prices are real, ingested, free data (ADR-0011, `fct_price_changes`).** The market already moves
  on its own between gameweeks; we don't have to invent or balance an economy. Mirroring FPL means
  the economy is realistic *at no balancing cost*.
- **The rules ARE the behavioural signal.** The −4 hit and the half-rise sell rule are precisely what
  create interesting decisions — taking a hit for upside, loss aversion, holding a riser. Strip them
  out and `fct_transfers` flattens into noise; the very analysis the CDP exists for loses its texture.
- **Solo maintainer, $0.** The faithful rules add bounded, deterministic complexity: track
  purchase price per holding, apply the sell-price formula against `fct_price_changes`, enforce
  bankable-free-transfer counting and the penalty. All cheap and testable — no external cost.
- **Validation lives in the API service layer (ADR-0015)** and the resulting facts in Postgres
  (ADR-0002); whatever we choose must be expressible as a transfer-validity check there.

## Decision

We will **mirror FPL's transfer and economy rules** (option: mirror), as specified in
[`../product/game-design.md`](../product/game-design.md) §5: 1 free transfer/gameweek bankable to 2,
−4 points per extra transfer, buy at current price, FPL sell-price rule (gains halved and rounded
down, falls in full), bank must stay ≥ £0.

Following the house idiom (ADR-0012, where the SLO ADR fixes the policy and the SLO spec holds the
tunable numbers): **this ADR fixes the decision to mirror FPL; the exact rule values live in
game-design §5 as the living, playtest-tunable spec.** Chips and head-to-head leagues remain Phase 2
(game-design §6–§7) and are out of scope here.

## Options considered

| Option | Pros | Cons |
|---|---|---|
| **Mirror FPL (chosen)** | Realistic economy at zero balancing cost — prices are real ingested data; the −4 hit + half-rise sell rule are the source of the behavioural signal we want to study; faithful to FPL so reference data and player expectations match; complexity is bounded and deterministic, hence testable | More service-layer validation (bankable counts, penalty, bank ≥ 0); requires tracking purchase price per holding and applying the sell-price formula against `fct_price_changes` |
| Simplify (sell at current price, no hits, free transfers) | Least code; trivial validation | Flattens `fct_transfers` into low-information rows — guts the "behaviour vs performance" analysis that is the project's payoff; *less* realistic despite real prices; saves little since the hard part (price ingestion) exists regardless |
| Invent our own economy (custom prices/rules) | Full creative control; a balancing exercise to learn from | Must invent and balance an economy by hand — expensive, off-goal, and throws away the free, real, self-moving FPL market; not worth it for a data-showcase project |

## Consequences

- **Positive:** `fct_transfers` carries the full texture of real managerial decisions — hits taken,
  bankings, gains realised or held — which is exactly what makes `mart_engagement_vs_performance`
  worth building. The economy is realistic and self-balancing for free because it rides on ingested
  FPL prices. Rule values stay tunable in the game-design spec without re-opening this ADR.
- **Negative / tradeoffs:** We carry the bookkeeping the faithful rules demand — per-holding purchase
  price, the sell-price formula evaluated against the price history, and bankable-transfer/penalty
  accounting in the API layer. We accept this as bounded, deterministic, and well-suited to unit
  tests; it is the cost of the data richness, and the hard dependency (price ingestion) exists under
  either option anyway.
- **Follow-ups:**
  - ADR-0015 (API) — owns transfer-validity enforcement: positional/club/budget constraints, bankable
    free-transfer counting, the −4 penalty, and bank ≥ £0.
  - ADR-0011 (FPL source) / `fct_price_changes` — supplies current prices and the price history the
    sell-price rule reads.
  - ADR-0005 (dbt) — models `fct_transfers` into the Silver/Gold marts feeding
    `mart_engagement_vs_performance` (ADR-0013).
  - ADR-0002 (Postgres) — `fct_transfers` and per-holding purchase price are OLTP system-of-record
    writes.
  - [`../product/game-design.md`](../product/game-design.md) §5 remains the living economy spec; §6
    (chips) and §7 (H2H leagues) are deferred Phase 2 decisions.

# ADR-0013: Identity stitching — operational ↔ behavioral identity

- **Status:** Accepted
- **Date:** 2026-06-15
- **Deciders:** Stephen Delaney
- **Tags:** data-platform, cdp, identity, gold-marts

## Context

The platform deliberately runs two identity domains (ADR-0002, ADR-0006):

- **Operational identity** — `user_id`, the system-of-record key for a manager in RDS Postgres. It
  drives squads, transfers, budgets, lineups.
- **Behavioral identity** — PostHog's `distinct_id`, the key under which product events and person
  profiles accumulate in the CDP.

The headline analytical question — *"do managers who buy in-form players retain and engage longer?"*
— requires joining these two domains per manager. That join **is the centerpiece** of the project
(see [architecture §4](../architecture/system-architecture.md#4-identity-stitching--gold-marts));
the Gold mart `mart_manager_360` and the downstream `mart_engagement_vs_performance` depend on it.

Forces at play:

- **A user is anonymous before they are known.** PostHog assigns an anonymous `distinct_id` on first
  visit (browse the landing page, start signup). Operational identity only exists *after* signup,
  when Cognito (ADR-0016) mints the account. We must not orphan the pre-signup behavioral events.
- **One person, many `distinct_id`s.** Multiple devices/sessions before login each get their own
  anonymous id; they must resolve to the one operational user.
- **Constraints:** $0 (PostHog Cloud free, no reverse-ETL/CDP-resolution product); solo maintainer;
  we *control our own auth*, so we do not need probabilistic matching — we can engineer a
  deterministic key. Bronze must stay source-faithful (ADR-0003) — no business logic at ingest.

This ADR fixes **what the canonical key is, where the stitch happens, and the join contract** Gold
marts rely on. Related: ADR-0002 (SoR), ADR-0006 (PostHog/CDP), ADR-0016 (Cognito), ADR-0005 (dbt).

## Decision

We will make **Cognito's `sub` the single canonical `user_id`** across both domains and stitch
**deterministically**:

1. **At the source — align the keys.** On every authenticated session the app calls PostHog
   `identify(distinct_id = <Cognito sub>)`. PostHog's identify merges the current **anonymous**
   `distinct_id` into the known person via its `$anon_distinct_id` alias, so pre-signup events are
   retained and future events land under the operational `user_id`. The app **never invents its own
   user id** — `sub` is the one key minted at signup and reused everywhere (OLTP rows, JWT, PostHog).

2. **In the warehouse — materialize a resilient identity spine, not a raw equality.** dbt-Silver
   (ADR-0005) builds **`dim_identity_map`**: one row per `user_id` with the set of `distinct_id`s
   that resolve to it, derived from PostHog `$identify`/person-distinct-id records *unioned with* the
   trivial `user_id = distinct_id` mapping. Gold marts **join through `dim_identity_map`**, never by
   equating the columns inline. Bronze stays source-faithful; all stitching lives in modeled,
   testable SQL.

So: deterministic key alignment **at emit time**, resilient resolution **at transform time**,
source-faithful capture **at ingest**.

## Options considered

| Option | Pros | Cons |
|---|---|---|
| **A (chosen): canonical `sub` + PostHog `identify`, resolved via `dim_identity_map` in dbt** | Deterministic — we own auth, so no guessing; handles anon→known merge and multi-device via PostHog's alias graph + a modeled spine; Bronze stays raw; the map is a tested, auditable dbt model; $0 | Requires the app to call `identify` correctly on every login (a real failure mode — needs a dbt test for unmapped ids); one extra Silver model to maintain |
| B: query-time equality `user_id = distinct_id` in Gold, no identity model | Simplest; zero extra models | Brittle — silently drops anonymous/pre-signup and multi-device events; no audit trail; no place to assert "every active user resolves"; bakes a fragile assumption into every mart |
| C: probabilistic stitching (email / IP / device fingerprint) | Works when you *don't* control identity | Unnecessary — we control Cognito; privacy-heavy; false merges; complex for a solo $0 project |
| D: PostHog as the identity authority (reverse-ETL `distinct_id` back into OLTP) | One system "owns" identity | Inverts the SoR (ADR-0002) — the free CDP becomes upstream of the database of record; PostHog free tier has no reverse-ETL; wrong dependency direction |

## Consequences

- **Positive:** The join that justifies the whole two-domain design becomes **deterministic and
  testable**. `dim_identity_map` is a single, auditable seam — every Gold mart joins through it, so
  identity logic has exactly one home. Anonymous→known and multi-device cases are handled by
  construction, not patched per query. Costs $0 and uses only owned primitives (Cognito `sub`,
  PostHog identify, dbt).
- **Negative / tradeoffs:** Correctness depends on the app reliably calling `identify` with `sub` —
  a missed call leaves behavioral events stranded under an anonymous id. We accept this and **defend
  it with a dbt test**: assert the share of active-user events that resolve through `dim_identity_map`
  stays above a threshold (this is the **correctness SLI** in [`../slo/data-platform-slos.md`](../slo/data-platform-slos.md)).
  We also accept one extra Silver model and a small amount of duplicate-event risk from PostHog
  merges, deduped in Silver (`freeze` contract). Pre-PostHog-account history that never identifies
  stays unattributed — acceptable.
- **Follow-ups:**
  - ADR-0016 (Cognito) — must confirm `sub` is the surfaced user key in the JWT and OLTP.
  - ADR-0006 (PostHog) — wire `identify`/`reset` (on logout) into the web + API event hooks.
  - ADR-0005 (dbt) — own `dim_identity_map` + the resolution test; **runbook** for an
    "identity-resolution-rate breach" (an unmapped-ids spike → app `identify` regression).
  - ADR-0012 (SLO/error-budget) — register identity-resolution rate as a correctness SLI.

## Join contract (for `mart_manager_360`)

```
dim_user (Silver, business)         ──┐
  user_id  PK                          │  user_id
                                        ├── dim_identity_map (Silver) ──┐
dim_person (Silver, engagement)     ──┘  user_id ↔ {distinct_id…}       │
  distinct_id  PK                                                        │ user_id
                                                                          ▼
fct_transfers (user_id) ───────────────────────────────────────►  mart_manager_360
fct_events    (distinct_id ─via map─► user_id) ────────────────►   (grain: one row per user_id)
```

- **Grain:** one row per `user_id`.
- **Rule:** behavioral facts (`fct_events`) are mapped to `user_id` **only** via `dim_identity_map`;
  business facts (`fct_transfers`, lineups, budgets) already carry `user_id`.
- **Test:** every `user_id` in `dim_user` resolves to ≥1 `distinct_id` in `dim_identity_map`, and the
  resolved-event share stays above the correctness-SLI threshold.

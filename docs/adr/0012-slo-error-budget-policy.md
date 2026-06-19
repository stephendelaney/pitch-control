# ADR-0012: SLO + error-budget policy

- **Status:** Accepted
- **Date:** 2026-06-16
- **Deciders:** Stephen Delaney
- **Tags:** observability, sre, reliability, data-platform

## Context

The platform has two reliability surfaces — the **request path** (the app people use) and the
**data path** (the pipeline behind it) — and SLIs/SLOs for both are already sketched in
[`../slo/data-platform-slos.md`](../slo/data-platform-slos.md). What is *not* yet recorded is the
**governance decision**: do we formally run an **error-budget regime**, and if so, what is the
budget, what happens when it burns, and how do these targets bind day-to-day work?

This ADR exists to make that policy an explicit, reviewable decision rather than an implicit habit —
and to give the SLI doc a decision it implements, the same way ADR-0013 points here to "register
identity-resolution rate as a correctness SLI."

Forces / constraints:
- **Solo maintainer, $0 tooling.** Any reliability process has to be cheap to run and impossible to
  ignore; an elaborate SLA regime with no one to page is theatre.
- **Learning goal: SRE-for-data.** The point is to *practise* SLOs/error budgets/runbooks, so the
  decision must be real enough to constrain behaviour, not a decorative table.
- **Batch, not 24/7.** The data path runs a handful of times a day; "is it fresh/complete/correct?"
  matters more than nines of uptime. The request path is a thin serverless app where golden signals
  suffice.
- **Targets must start loose and tighten.** Early data is noisy and the pipeline is immature;
  premature-tight SLOs would burn budget on day one and discredit the whole regime.

## Decision

We will **adopt an SLO + error-budget policy** as the platform's reliability-governance mechanism,
with [`../slo/data-platform-slos.md`](../slo/data-platform-slos.md) as the **living SLI/SLO spec**
(ADRs record the *decision*; the spec holds the current numbers, which are expected to move).

Specifically:

1. **Primary error budget is on data Freshness (data-path SLI 1):** Gold refreshed by 08:00 local on
   ≥ 99% of days → a budget of ~7 missed refreshes per rolling 30 days. This is the one budget that
   **gates feature work**.
2. **Burn policy:** when the freshness budget is exhausted, **feature work pauses** and the next
   change must be a reliability improvement (root-cause fix, new test, hardened runbook) until the
   budget recovers. When the budget is healthy, ship freely — the budget *permits* risk; it is not a
   goal of zero failures.
3. **Other SLIs are tracked, not budgeted** (pipeline success, completeness, correctness, and the
   request-path golden signals): they raise alerts and feed the monthly review, but only Freshness
   preempts feature work. Keeps the regime enforceable for one person.

   *Why Freshness is the right — and sufficient — gate:* we **budget on the user-facing symptom, not
   the internal cause.** Freshness is the symptom (is the Gold mart current?); pipeline-success and
   completeness are *causes/diagnostics* the user never observes directly. Any cause that actually
   harms the user — a terminal failure with no retry margin left in the window — surfaces *as* a
   freshness miss and is caught by the budget anyway; a failure that retries and still lands before
   the deadline correctly does **not** gate, because the user got optimal service. So Freshness
   subsumes the data-path causes without us having to gate each one. These are different mechanisms:
   **alerting** wakes the maintainer on the *cause* (so it gets fixed); the **error budget** governs
   the feature-vs-reliability tradeoff on the *symptom*. Pipeline-success belongs to the first.

   Pipeline-success stays a tracked SLI precisely because it is a **leading indicator** where
   Freshness is **lagging**: a pipeline that fails-and-retries frequently is burning its resiliency
   margin while Freshness still looks green — fragile, not healthy. That trend is what the monthly
   review watches. (The request-path golden signals *are* user-facing symptoms, but we leave them
   un-budgeted for now as a deliberate scoping call — the app is a thin, early serverless surface;
   revisit as it grows.)
4. **Register identity-resolution rate as a correctness SLI** (new data-path **SLI 5**), per ADR-0013:
   the share of active-user events that resolve through `dim_identity_map` must stay above a
   threshold, asserted by a dbt test. A breach signals an app `identify()` regression.
5. **Review cadence:** monthly — review budget burn, tighten any SLO that held comfortably, and write
   a [retro](../retros/) for any breach.

## Options considered

| Option | Pros | Cons |
|---|---|---|
| **Error-budget policy, single gating budget on Freshness (chosen)** | Real constraint with exactly one enforceable rule — fits a solo maintainer; matches the SRE-for-data learning goal; $0 (built on `ops.pipeline_runs` + elementary + Healthchecks.io); budgets *permit* risk so feature velocity isn't held hostage to zero-failure | Requires the discipline to actually pause features on burn; a single gating SLI can mask problems in the un-budgeted ones if the monthly review is skipped |
| Best-effort, no formal targets | Zero process overhead; never "blocked" | No reliability contract, nothing to practise, no signal when the platform is degrading; abandons the explicit SRE learning track |
| Hard SLAs / aim for 100% | Feels rigorous; simple to state | Wrong model — 100% is the wrong target (no budget to spend on change), unaffordable to defend solo at $0, and would block all feature work the first time noisy early data trips it |
| Budget every SLI equally | Most "complete" coverage | Unenforceable for one person — competing budgets with no priority means none of them actually gate anything; process collapses into noise |

## Consequences

- **Positive:** Reliability becomes a **decision with teeth** — one clear rule (freshness budget
  burned → fix reliability next) that a solo maintainer can actually honour. The SLI numbers live in
  one spec that's free to evolve without re-opening this ADR. Cheap to run on tooling we already
  chose (`ops.pipeline_runs` from ADR-0007, elementary from ADR-0005, Healthchecks.io). Gives the
  SRE-for-data learning track something concrete to exercise, and gives ADR-0013's correctness
  concern a registered, tested home.
- **Negative / tradeoffs:** Only Freshness gates work, so a slow degradation in an un-budgeted SLI
  (e.g. completeness drift) can hide until the **monthly review** — we accept this and lean on
  alerts + the review to catch it. The policy is only as good as the discipline to honour the burn
  rule; with no second person to enforce it, a skipped retro or an ignored pause is a real failure
  mode. Starter SLOs are deliberately loose and may need several tightening cycles before they mean
  much.
- **Follow-ups:**
  - [`../slo/data-platform-slos.md`](../slo/data-platform-slos.md) — add identity-resolution rate as
    **SLI 5** (done alongside this ADR).
  - ADR-0005 (dbt) — owns the `dim_identity_map` resolution test backing SLI 5; **runbook** for an
    identity-resolution-rate breach.
  - ADR-0007 (orchestration) — `ops.pipeline_runs` is the source of truth for the freshness/success/
    completeness SLIs measured here.
  - Roadmap Wk 3 (`ops.pipeline_runs` + elementary) and Wk 4 (Metabase Ops dashboard) make these SLIs
    observable; error-budget-in-practice is a Wk 5+ item.
  - **Future monitoring/observability ADR** (unnumbered) — this ADR fixes *what* we measure and *how
    it binds work*; a later decision should cover the **alerting + observability** half of the story
    (the cause-side mechanism above): how leading indicators like pipeline-success page the
    maintainer, alert routing/thresholds, and how `ops.pipeline_runs` + elementary + CloudWatch +
    Healthchecks.io compose into a coherent monitoring layer. Deferred until there's a running
    pipeline to observe (Wk 3+).

# Platform SLOs (request path + data path)

The project has two reliability surfaces, and the SRE story covers both:

1. **Request path** — the app people actually use. Classic "golden signals": is it up, fast, and
   error-free? (Section A.)
2. **Data path** — the pipeline behind it. Not "is the API up?" but **"is the data fresh, complete,
   and correct?"** (Section B.)

SLOs start loose and tighten as the platform matures.

## A. Request-path SLOs (the app people use)

| # | SLI | Definition | SLO (starter) | Measured by |
|---|---|---|---|---|
| A1 | **Availability** | successful responses ÷ total (non-5xx) | ≥ 99.5% / 30d | API Gateway + CloudWatch |
| A2 | **Latency** | p95 API response time | < 400ms p95 | CloudWatch metrics |
| A3 | **Error rate** | 5xx ÷ total requests | < 0.5% / 30d | CloudWatch + API Gateway logs |

These are thin on purpose — a solo serverless app. They exist so the "thing people use" has a
reliability contract, not just the pipeline.

## B. Data-path SLIs and SLOs

| # | SLI | Definition | SLO (starter) | Measured by |
|---|---|---|---|---|
| 1 | **Freshness** | `now() − max(loaded_at)` on Gold marts | Gold refreshed by 08:00 local, ≥ 99% of days | `ops.pipeline_runs` + elementary freshness test |
| 2 | **Pipeline success** | **first-attempt** green scheduled runs ÷ total scheduled runs (counts pre-retry status, so transient fragility stays visible) | ≥ 99% per rolling 30d | GitHub Actions run status + `ops.pipeline_runs` |
| 3 | **Correctness** | critical dbt tests passing | 100% critical; warn-tests tracked, not budgeted | `dbt build` / `run_results.json` |
| 4 | **Completeness** | actual ÷ expected rows per gameweek load | ≥ 99.5% | elementary volume test + reconciliation model |
| 5 | **Identity-resolution rate** | active-user events resolving through `dim_identity_map` ÷ active-user events | ≥ 95% (starter) | dbt test on `dim_identity_map` (ADR-0013) |

## Error budget policy

> Governed by [ADR-0012](../adr/0012-slo-error-budget-policy.md). Only **Freshness** gates feature
> work; the other SLIs are **tracked, not budgeted** — they alert and feed the monthly review.

- The **primary budget** is on Freshness (SLI 1): 99% of days = a budget of ~7 missed refreshes per
  rolling 30 days.
- **When the budget is burned:** feature work pauses; the next change must be a reliability
  improvement (fix root cause, add a test, harden a runbook) until the budget recovers.
- **When the budget is healthy:** ship features freely. The budget *permits* risk — it is not a
  goal of zero failures.

## Observability backing these SLOs (all free)

- **`ops.pipeline_runs`** — every pipeline stage writes start/end/status/rowcount. Source of truth
  for SLIs 1, 2, 4. Surfaced in a Metabase **Ops dashboard** (dogfooding our own BI).
- **elementary-data** — dbt package for freshness / volume / schema-drift / anomaly monitoring.
- **Healthchecks.io** — free dead-man's-switch: each scheduled run pings on success; silence alerts.
- **CloudWatch** (free tier) for Lambda logs; **GitHub Actions** notifications on failed runs.

## Review cadence

Monthly: review budget burn, tighten any SLO that held comfortably, write a retro for any breach.

# ADR-0006: PostHog as product analytics + CDP

- **Status:** Accepted
- **Date:** 2026-06-19
- **Deciders:** Stephen Delaney
- **Tags:** data-platform, cdp, analytics, behavioral

## Context

The platform deliberately runs a **behavioral identity domain** alongside the OLTP system of record
(ADR-0002): product events and person profiles that answer *"do managers who buy in-form players
retain and engage longer?"* This requires a **product-analytics / CDP** layer that (a) captures
anonymous pre-signup behavior, (b) supports `identify` to merge anonymous → known under the canonical
`user_id` (Cognito `sub`, ADR-0013/0016), and (c) lets us export raw events into the Bronze lake
(ADR-0003) so dbt (ADR-0005) can model `dim_person`/`fct_events` and join them through
`dim_identity_map`.

Constraints: $0 / generous free tier; solo maintainer; we **own our own auth**, so deterministic
identity stitching is possible (ADR-0013); events must be exportable to S3 so the warehouse — not the
vendor — remains the analytical authority (Bronze stays source-faithful, ADR-0003).

## Decision

We will use **PostHog Cloud (free tier)** as the product-analytics + CDP layer. The web app and API
(ADR-0014/0015) emit events via the PostHog SDK; on every authenticated session the app calls
`identify(<Cognito sub>)` and `reset()` on logout (ADR-0013). Raw PostHog events + person/distinct-id
records are **exported into Bronze** for dbt to model. PostHog is the **capture + behavioral store**;
it is **not** the identity authority (the OLTP SoR is — ADR-0002/0013).

## Options considered

| Option | Pros | Cons |
|---|---|---|
| **PostHog Cloud free (chosen)** | Generous free event tier; events + autocapture + funnels/retention UI; native `identify`/anon-merge alias graph (exactly what ADR-0013 needs); event export to S3; OSS ethos, one tool for analytics + CDP-lite; strong learning surface | Free tier has event/retention caps; export cadence/granularity is tier-limited; not a full enterprise CDP (no reverse-ETL on free) — fine, we don't want it (ADR-0013 option D) |
| Self-hosted PostHog | No vendor caps; full control | Wants standing infra (containers/DB) — **not $0**, real ops burden for a solo project |
| Amplitude / Mixpanel free | Polished product-analytics UX | Weaker self-serve raw-event export to our own lake; more vendor-bound; CDP/identity-merge ergonomics less aligned with the warehouse-as-authority model |
| Roll our own events → S3 | Total control, zero vendor | Re-invents SDK, autocapture, identify/merge, funnels UI; huge build for a solo project; defeats the point |
| Segment (CDP) free | Purpose-built CDP routing | Free tier tight; routing tool, not an analytics UI; overkill — we need capture + behavioral modeling, not multi-destination routing |

## Consequences

- **Positive:** Behavioral capture, anonymous→known merge, and exploration UI come for free and map
  directly onto the identity-stitching design (ADR-0013). Exporting raw events to Bronze keeps the
  **warehouse the analytical authority** and lets dbt model engagement marts (ADR-0005). Good,
  realistic CDP learning surface at $0.
- **Negative / tradeoffs:** Free-tier event caps and export limits constrain volume/cadence — fine at
  this scale; we monitor ingest freshness as an SLI (ADR-0012). Correctness depends on the app
  calling `identify`/`reset` reliably — defended by the resolution-rate test (ADR-0013). PostHog
  merges can duplicate events; deduped in Silver (ADR-0013).
- **Follow-ups:** ADR-0013 (canonical key + `dim_identity_map`), ADR-0014/0015 (SDK wiring + event
  hooks), ADR-0016 (Cognito `sub` as `distinct_id`), ADR-0010 (dlt exports PostHog events → Bronze),
  ADR-0012 (ingest-freshness + resolution-rate SLIs).

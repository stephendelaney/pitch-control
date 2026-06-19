# ADR-0001: Record architecture decisions

- **Status:** Accepted
- **Date:** 2026-06-13
- **Deciders:** Stephen Delaney
- **Tags:** process, meta

## Context

This is a personal project, but a deliberate goal is to practice production engineering rigor and
to *learn systematically*. Decisions made early (which database, which warehouse engine, which
orchestrator) carry rationale that is easy to forget. Without a record, future-me re-litigates
settled questions and loses the "why."

## Decision

We will capture every architecturally significant decision as a Markdown ADR in `docs/adr/`,
using the lightweight [MADR](https://adr.github.io/madr/) style defined in `template.md`. ADRs are
immutable once Accepted; we supersede rather than edit.

## Options considered

| Option | Pros | Cons |
|---|---|---|
| **MADR-lite Markdown ADRs (chosen)** | Versioned with the code, reviewable in PRs, low ceremony | Manual discipline required |
| Wiki / Notion | Rich editing | Drifts from code, not in version control |
| No record | Zero effort | Rationale is lost; the explicit anti-goal |

## Consequences

- **Positive:** Decisions are auditable and reviewable; onboarding (even future-self) is fast.
- **Tradeoffs:** Requires the discipline to actually write them before/at decision time.
- **Follow-ups:** Seed ADRs for decisions already taken (DB engine, lake, warehouse, orchestration,
  CDP, BI, IaC, ingestion, data source, SLO policy, identity stitching). See `adr/README.md`.

# ADR-0007: GitHub Actions + Lambda for orchestration (vs Airflow / MWAA)

- **Status:** Accepted
- **Date:** 2026-06-14
- **Deciders:** Stephen Delaney
- **Tags:** data-platform, orchestration, ci-cd, infra

## Context

The pipeline needs an **orchestrator** to schedule and sequence the batch DAG: land Bronze with dlt
(ADR-0010), run Silver/Gold dbt-duckdb transforms (ADR-0004/0005), and publish marts for BI. We need
scheduling, dependency ordering, retries, logging, and secret handling — at **$0**, with **no
always-on infrastructure**, for a **solo maintainer**.

This is the richest tradeoff in the stack: the "proper" data-engineering answer is Airflow, but
Airflow wants a scheduler + metadata DB + workers running 24/7, which violates both the cost and the
ops-surface constraints for a batch job that runs a handful of times a day.

Forces:
- Workload is **scheduled batch**, low-frequency (gameweek cadence + daily refresh) — not streaming,
  not sub-minute, not hundreds of tasks.
- Code already lives in GitHub; CI/CD (ADR via Terraform OIDC, ADR-0009) is there too. Co-locating
  orchestration with CI avoids a second control plane.
- Some steps may need more runtime/memory or AWS-VPC proximity to RDS than a hosted runner gives.

## Decision

We will orchestrate with **GitHub Actions** as the **scheduler + DAG driver** (`cron` triggers,
job/needs dependencies, matrix, retries, secrets via OIDC — ADR-0009), invoking **AWS Lambda** for
steps that need AWS-native execution (VPC access to RDS, heavier/isolated compute, or event-driven
triggers). GitHub Actions is the control plane; Lambda is a worker for AWS-bound steps. **No Airflow.**

## Options considered

| Option | Pros | Cons |
|---|---|---|
| **GitHub Actions + Lambda (chosen)** | $0 (Actions free minutes + Lambda free tier); zero standing infra; orchestration co-located with code/CI; OIDC = no static keys (ADR-0009); Lambda gives VPC/RDS access + isolated compute when needed; trivially enough for low-freq batch | Actions is a CI tool, not a purpose-built orchestrator — no rich DAG UI, lineage, or backfill ergonomics; cross-job state is manual; `needs:` graphs get awkward past ~dozens of tasks |
| Airflow (self-hosted) | Real orchestrator: DAGs, backfills, retries, rich UI, huge ecosystem | Wants 24/7 scheduler + metadata DB + workers — **not $0**, real ops burden; massive overkill for a few daily batch runs |
| Amazon MWAA (managed Airflow) | Managed Airflow, no self-host ops | **~$0.49/hr minimum — not free**; disqualified on the $0 constraint alone |
| Step Functions + EventBridge | AWS-native, serverless, visual state machine; cheap | Orchestration logic lives in AWS away from the code/CI; steeper IaC; another console to learn; less reusable than CI we already run |
| Dagster / Prefect (Cloud free tier) | Modern data-orchestrator ergonomics, asset/lineage model | Adds a third control plane + agent; free tiers are credit/seat-limited; more than a solo batch job needs now |

## Consequences

- **Positive:** Genuinely $0 with **no always-on infrastructure** — schedules fire, jobs run, runners
  vanish. Orchestration sits **next to the code and CI/CD**, one control plane, one auth story (OIDC,
  ADR-0009). Lambda covers the cases hosted runners can't (RDS-in-VPC, isolated/heavier compute).
  Right-sized for low-frequency batch and an excellent learning surface for CI-as-orchestrator.
- **Negative / tradeoffs:** We forgo a real orchestrator's **DAG UI, lineage, and backfill/replay
  ergonomics**; visibility into run history is whatever Actions + our own logging gives us. Complex
  inter-task data passing is manual. We mitigate observability with an **`ops.pipeline_runs`** table
  (run id, status, rows, timings) and dbt/elementary artifacts, and we keep the DAG small. If task
  count or backfill needs outgrow `needs:` graphs, that is the explicit trigger to revisit
  Dagster/Prefect.
- **Follow-ups:** ADR-0009 (Terraform + OIDC, the auth this relies on), ADR-0010 (dlt jobs invoked
  here), ADR-0012 (SLOs — pipeline-success/freshness SLIs are measured from runs orchestrated here).
  Observability via `ops.pipeline_runs` + elementary is a roadmap Wk 3 item. Runbook:
  [`runbooks/bronze-load-failure.md`](../runbooks/bronze-load-failure.md).

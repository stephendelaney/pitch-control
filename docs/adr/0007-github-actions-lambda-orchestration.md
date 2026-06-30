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

## Amendment — 2026-06-29 (Accepted)

> Status: **✅ Accepted** (ratified 2026-06-30). Extends the Consequences above; does not change the
> chosen decision. Lambda remains the default worker.

**Worker-compute overflow target: AWS Fargate (per-step), not EC2.** The original decision names
orchestration complexity ("`needs:` graphs outgrow ~dozens of tasks") as the trigger to revisit. This
amendment adds the **other** axis on which Lambda can be outgrown — **per-step resource and runtime
limits** — and fixes the target so it isn't decided under incident pressure:

- **The limits that bite the data path.** Lambda caps a single invocation at **15 min wall-clock**,
  **10 GB memory** (CPU scales with memory), and **10 GB `/tmp`** scratch. DuckDB (ADR-0004) is
  deliberately memory- and local-disk-hungry and spills to disk under pressure, so a cold/full
  **dbt build** or a **dlt backfill** over a season of history is the realistic way a step crosses
  these ceilings. The 15-min cap is a **cliff, not a slope**: the job is *killed mid-run*, which then
  surfaces as a breached freshness SLO (ADR-0012) — i.e. you learn by failing.
- **Migrate on a leading indicator, not the SLO.** Because the timeout is a hard cliff, the trip-wire
  is a **capacity leading indicator**, not the lagging freshness SLO. From `ops.pipeline_runs`
  (already capturing per-run timings), derive **step duration as % of the 15-min cap** and **peak
  memory as % of 10 GB**; alert at **~70%**. That fires *before* the kill, turning a migration into
  planned work instead of an incident. (The SLO/error-budget path in ADR-0012 remains the right
  governor for *gradual* degradation — e.g. API cold-start p99 tail — but not for this hard limit.)
- **Why Fargate and not EC2.** Fargate keeps the no-server-management ops win (no AMI, no patching, no
  SSH surface) while removing the 15-min ceiling and lifting memory/CPU (≤120 GB). The move is
  **per-step**: only the one job that outgrew the box goes to Fargate; the rest of the DAG stays
  Lambda-default, still driven by GitHub Actions. EC2 is rejected for the same standing-infra/ops
  reasons as the original ADR.
- **Cost honesty.** Fargate has **no always-free tier** — it bills per vCPU-second/GB-second *while a
  task runs*. For short, low-frequency batch the cost is small and bounded by run duration (no idle
  charge), so it stays within the spirit of the $0 constraint, but it is **not literally $0** and
  should be acknowledged when the first step migrates.

See also the ADR-0002 amendment (2026-06-29) for the Lambda→RDS connection-management mitigation that
the dlt-from-Postgres step depends on.

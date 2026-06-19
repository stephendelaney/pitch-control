# ADR-0015: API — API Gateway + Lambda (FastAPI)

- **Status:** Accepted
- **Date:** 2026-06-19
- **Deciders:** Stephen Delaney
- **Tags:** application-layer, api, backend, infra

## Context

Between the SPA (ADR-0014) and the OLTP system of record (ADR-0002) sits the **application layer**:
the API that authenticates requests (Cognito, ADR-0016), enforces game rules (squad/lineup/transfer
validation per the game-design spec + ADR-0018), writes to Postgres, and emits server-side PostHog
events (ADR-0006). It is on the **synchronous request path**, so its golden-signal SLOs (latency,
errors, traffic, saturation) are tracked alongside the data-path SLOs (ADR-0012). We need a backend
that runs at **$0 / no always-on server** and integrates cleanly with the AWS stack.

Constraints: $0 (free tier, no idle compute); solo maintainer; Python (shared language with dlt/dbt
tooling, ADR-0010/0005); must validate Cognito JWTs (ADR-0016), reach RDS in-VPC (ADR-0002), and be
Terraform-provisioned (ADR-0009).

## Decision

We will build the API as **FastAPI running on AWS Lambda behind API Gateway** (HTTP API), with Cognito
as the JWT authorizer (ADR-0016). Lambda gives serverless, scale-to-zero compute with **VPC access to
RDS** (the same Lambda-in-VPC capability ADR-0007 relies on); FastAPI provides typed routing,
validation (Pydantic), and OpenAPI docs. Game-rule enforcement and the canonical `user_id` (`sub`)
writes live here. **No always-on API server (no ECS/EC2).**

## Options considered

| Option | Pros | Cons |
|---|---|---|
| **API Gateway + Lambda (FastAPI) (chosen)** | $0 scale-to-zero (Lambda + API GW free tier); Cognito JWT authorizer built in; Lambda-in-VPC reaches RDS (ADR-0002/0007); FastAPI = typed routes, Pydantic validation, free OpenAPI; Python parity with dlt/dbt; Terraform-provisioned (ADR-0009) | Cold starts on the request path (latency tail — an SLI to watch); Lambda packaging/VPC-cold-start care; 15-min/size limits (irrelevant for CRUD); per-request model differs from a long-lived server |
| ECS Fargate / EC2 (FastAPI server) | Always-warm, no cold start, simpler long-lived runtime | Standing compute — **not $0**; more ops; over-scaled for low traffic |
| AWS App Runner | Managed containers, less ops | Min running cost — not durably $0; less hands-on than Lambda+IaC |
| API Gateway + direct service integrations (no Lambda) | Less compute | Can't host real game-rule logic; pushes complexity into VTL/mappings; poor fit for validation |
| Node/Express on Lambda | Popular | Splits language from the Python data tooling; no strong reason over FastAPI here |

## Consequences

- **Positive:** Serverless, scale-to-zero API at $0 with native Cognito auth and in-VPC RDS access.
  FastAPI gives typed validation + free OpenAPI, and Python keeps one language across API + data
  tooling. The request path becomes a first-class **golden-signals** learning surface (ADR-0012).
  Terraform-provisioned alongside the rest of the stack (ADR-0009).
- **Negative / tradeoffs:** **Cold starts** add latency-tail risk on a synchronous path. Realistic
  cold start for this stack is **~1–2s** (Python + FastAPI/Pydantic, in-VPC); modern **Hyperplane
  ENIs** mean the VPC penalty is now sub-second, not the ~8–10s of pre-2019 Lambda. The risk here is
  unusual because traffic is **low**: cold starts are normally a p99 tail, but if few enough requests
  arrive per idle window (>5% landing cold), they drag **p95 over the 400ms target** (ADR-0012, SLI
  A2). So the thing to watch is the cold-start **rate**, not just p95 latency — at low traffic they're
  the same problem. Cold starts hurt **latency only** (A2): a slow 2xx is not a 5xx, so availability
  (A1) and error rate (A3) are unaffected. The per-request execution model is more constrained than a
  long-lived server — acceptable for CRUD + rule validation at this scale.
- **Mitigation (keeps $0):** a scheduled **keep-warm** ping — EventBridge every ~5 min invoking a
  lightweight `/health` route — keeps one execution environment (Python process, imports, **in-VPC RDS
  connection**) alive. Because the whole API is **one FastAPI app in one Lambda function**, warming
  `/health` warms *every* route in that function (shared process), so this single timer covers the app.
  It only keeps **one** environment warm (concurrency 1), which fits a single-user-at-a-time app;
  concurrent bursts still cold-start. Cheap latency wins regardless: **ARM/Graviton** + a **lean
  deployment package** shave the cold start itself. **Provisioned concurrency** guarantees warm but
  **breaks $0** — reserve it as the escape hatch only if keep-warm proves insufficient. Note: this
  property holds only while the API stays a single Lambda; splitting into multiple functions means each
  needs its own keep-warm.
- **Follow-ups:** ADR-0016 (Cognito JWT authorizer + `sub`), ADR-0002 (RDS writes, in-VPC),
  ADR-0014 (the SPA client), ADR-0006/0013 (server-side events + `identify` correctness),
  ADR-0018 (transfer/economy rules enforced here), ADR-0009 (Terraform: API GW + Lambda + IAM),
  ADR-0012 (request-path golden-signal SLOs). C4 L3 component diagram for the API is a learning-track
  next step (architecture doc).
- **Keep-warm implementation intent (Wk 1):** a `/health` route on the FastAPI app, hit on an
  EventBridge schedule (~5 min), serves as both health check and keep-warm — one call, two jobs. Three
  forks for the implementer: (1) **invoke Lambda directly** (cheap, skips API GW) vs HTTP-ping the
  route; (2) **keep these pings out of the SLO metrics** (ADR-0012 A1/A2/A3) — a direct invoke avoids
  polluting API GW/CloudWatch, or else exclude the `/health` path; (3) **shallow** (process-only) vs a
  light DB-touching check that also keeps the in-VPC RDS connection warm.

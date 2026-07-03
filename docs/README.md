# Engineering Knowledge Base

This `docs/` tree is the project's **decision-capture and reliability system**. It exists so the
*rationale* behind the build survives — not just the code. Though this is a personal project, it
is run with production engineering rigor.

**Architecture is treated as a first-class deliverable** — modeled with the [C4 model](architecture/system-architecture.md)
(Simon Brown) and showcased as a skill on par with the implementation. The *how-we-decided* and the
*how-it's-shaped* matter as much as the running app.

| Area | Folder | Purpose |
|---|---|---|
| Product / game design | [`product/`](product/game-design.md) | The game's rules & mechanics, and the data each one generates |
| Architecture diagrams | [`architecture/`](architecture/system-architecture.md) | Mermaid diagrams: data flow, identity stitching, CI/CD |
| Architecture Decision Records | [`adr/`](adr/) | Why each significant choice was made, with options + tradeoffs |
| Service Level Objectives | [`slo/`](slo/) | What "reliable" means here: SLIs, SLOs, error budget |
| Runbooks | [`runbooks/`](runbooks/) | How to detect, diagnose, and fix known failure modes |
| Retros | [`retros/`](retros/) | Blameless postmortems; the learning loop back into ADRs/runbooks |
| Backlog | [`backlog.md`](backlog.md) | Reviewed improvement queue: decisions for Stephen + tasks delegable to a model |

## The DevOps quartet this project practices

1. **Infrastructure as Code** — Terraform provisions RDS, S3, and IAM/OIDC. Remote state in S3.
   Reproducibility means the MTTR for "rebuild everything" is minutes, not days.
2. **CI/CD** — GitHub Actions runs PR checks, `dbt build`, `terraform plan/apply` (via OIDC, no
   long-lived keys), and the scheduled ETL. Every change is tested and reversible.
3. **SRE / Data Reliability Engineering** — SLOs, error budgets, observability, runbooks, retros.
   For a data platform, "is it up?" becomes "is the data fresh, complete, and correct?"
4. **Decision log** — ADRs thread through all three so the *why* is never lost.

## The learning loop

```
Decision        ──►  write an ADR
Failure         ──►  write/extend a runbook + hold a retro
Retro action    ──►  new ADR or supersede an old one
SLO breach      ──►  error budget burned ──► reliability work preempts features
```

This loop is the point: the project is a vehicle for learning the *discipline*, with the football
manager domain as the fun surface.

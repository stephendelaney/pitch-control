# ADR-0009: Terraform for infrastructure-as-code

- **Status:** Accepted
- **Date:** 2026-06-19
- **Deciders:** Stephen Delaney
- **Tags:** infra, iac, ci-cd, security

## Context

The platform provisions real AWS resources — RDS Postgres (ADR-0002), the S3 medallion bucket +
lifecycle rules (ADR-0003), Lambda + IAM for orchestration (ADR-0007), Cognito (ADR-0016), API
Gateway (ADR-0015), CloudFront/S3 for the SPA (ADR-0014). These must be **declarative, versioned, and
reproducible**, and CI must deploy them **without static AWS keys** — ADR-0007 explicitly relies on
**OIDC** auth, which this ADR owns. Learning goal: practice IaC discipline (plan/apply, state, modules,
least-privilege IAM).

Constraints: $0 (no paid IaC backend); solo maintainer; everything lives in GitHub, so deploys run in
GitHub Actions (ADR-0007). State must live somewhere durable and free.

## Decision

We will use **Terraform** to provision all AWS infrastructure, with **remote state in S3** (a
dedicated state bucket, DynamoDB or S3 native locking) and **GitHub Actions OIDC → AWS IAM role** for
keyless deploys. CI runs `terraform plan` on PRs and `terraform apply` on the default branch via the
OIDC-assumed role with least-privilege policies. No long-lived AWS access keys exist.

## Options considered

| Option | Pros | Cons |
|---|---|---|
| **Terraform + S3 state + OIDC (chosen)** | $0; ubiquitous, the IaC skill to learn; mature AWS provider; S3 remote state is free + durable; OIDC = no static keys (the auth ADR-0007 needs); plan/apply review fits the PR/CI flow | HCL + state management to learn; state/locking must be set up carefully; drift is on us to watch |
| AWS CDK (TypeScript/Python) | Real-language IaC, good AWS ergonomics | CloudFormation under the hood (slower, AWS-only); less of the portable, conventional IaC skill; another runtime in CI |
| Pulumi | Real-language IaC, multi-cloud | Free tier centers on Pulumi-hosted state/SaaS; smaller ecosystem; Terraform is the more standard learning target |
| Raw CloudFormation | Native AWS, no extra tool | Verbose; AWS-locked; weaker module ecosystem; least transferable skill |
| ClickOps (console) | Fastest to first resource | Not reproducible/versioned; no review; defeats the IaC learning goal; drift-prone |

## Consequences

- **Positive:** All infra is declarative, code-reviewed, and reproducible from zero. OIDC keyless
  deploys give a clean, secret-light security story and are exactly the auth ADR-0007 assumes. Free,
  durable S3 state. Strong, transferable IaC + least-privilege-IAM learning surface (roadmap Wk 1).
- **Negative / tradeoffs:** HCL and Terraform **state** are real learning/operational surface — state
  bootstrap (the state bucket itself) is a chicken-and-egg step we create once by hand or with a
  minimal bootstrap config. Drift between console and code is possible; we keep changes IaC-only and
  could add drift detection later. Module structure starts simple and refactors as the surface grows.
- **Follow-ups:** ADR-0007 (consumes the OIDC role this defines), ADR-0002/0003/0014/0015/0016
  (resources provisioned here), ADR-0012 (IAM/least-privilege touches the security posture). Roadmap
  Wk 1 stands up the Terraform skeleton (RDS, S3 medallion, IAM/OIDC).

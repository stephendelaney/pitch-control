# ADR-0020: IAM authorization model — one role per compute identity, least privilege

- **Status:** ✅ Accepted (ratified 2026-07-03)
- **Date:** 2026-07-03
- **Deciders:** Stephen Delaney
- **Tags:** infra, security, iam, auth

## Context

Several ADRs each decide one slice of the security posture, but no single ADR states the **whole
authorization model** — so it's worth writing down the spine before the surface grows and the model
drifts into ad-hoc roles.

The forces:

- **Keyless everywhere possible.** ADR-0009/0007 already establish **GitHub OIDC → IAM role** for
  deploys: no long-lived AWS keys exist. ADR-0019 pushes the same ethos into runtime (Lambda reads
  SSM `SecureString` via its execution role — no stored credential). The open question is not *whether*
  to use roles but *how many roles, scoped how*.
- **Three distinct trust boundaries**, which is the entire model:
  1. **CI → AWS control plane** (build things) — OIDC-assumed role (ADR-0009).
  2. **App → AWS data plane** (runtime reads: SSM, RDS, S3) — compute execution/task role
     (ADR-0015 Lambda, ADR-0007 amendment Fargate overflow, ADR-0019 SSM, ADR-0003 S3).
  3. **Client → app** (runtime callers of the API) — **Cognito JWT** at the API Gateway authorizer
     (ADR-0016/0015). *Not an IAM concern; owned by those ADRs, referenced here for completeness.*
- **Cost + maintainer.** $0 marginal (IAM/OIDC/STS are free); solo maintainer, so the model must be
  *as simple as possible while robust* — the failure mode to avoid is per-service role sprawl that
  buys no real safety at this scale.

The design tension is **blast radius vs. simplicity**. A single all-powerful role is simplest but means
a leaked OIDC trust condition or a bad `apply` = full account. Per-resource roles minimize blast radius
but are over-engineering for one app. The right cut is **by trust boundary and privilege level, not by
service**.

## Decision

We will adopt **one IAM role per compute identity, scoped to its trust boundary and least-privileged to
its job**, under a single governing principle:

> **Every compute identity gets an IAM role; a static secret exists only where a role physically can't
> reach** (which, given Cognito for clients and SSM/OIDC for machines, is essentially nowhere on the
> AWS side — the only stored secret is the RDS password, per ADR-0019).

Concrete role inventory:

**Build plane (CI, OIDC-assumed — ADR-0009/0007):**

- **`tf-plan` role — read-only.** Trust: *any* branch/PR of the repo. Used by `terraform plan` on PRs.
  Read-only so untrusted PR code (forks, contributors, a compromised action) **cannot mutate** anything.
- **`tf-apply` role — write.** Trust: **scoped to `repo:<owner>/just-for-fun:ref:refs/heads/main`**.
  Used by `terraform apply` on the default branch only. This is the account's real mutation authority.
- **Bootstrap is out-of-band.** The OIDC provider, the state bucket/lock, and these two roles are
  themselves AWS resources (ADR-0009's chicken-and-egg). They are created **once** with local admin
  creds (or a minimal bootstrap config) and are **not assumable by CI** — CI can never grant itself
  IAM. IAM-write stays out of `tf-apply`'s policy where practical.

**Runtime plane (app → AWS):**

- **One shared Lambda execution role to start**, least-privileged to exactly: `ssm:GetParameter` +
  `kms:Decrypt` on the specific parameter path (ADR-0019), RDS connect/network, and the S3 medallion
  prefixes it needs (ADR-0003). **Split into per-function roles only when policies actually diverge** —
  not preemptively.
- **Fargate overflow (ADR-0007 amendment)** uses a task role with the same least-privilege posture when
  invoked.

**Client plane (client → app):** **unchanged — Cognito JWT** validated by the API Gateway authorizer
(ADR-0016/0015). Listed only so the model is complete across all three boundaries.

## Options considered

| Option | Pros | Cons |
|---|---|---|
| **Trust-boundary-scoped roles: `tf-plan`(ro, any ref) + `tf-apply`(write, `main`) + one runtime exec role, split-on-divergence (chosen)** | Blast radius cut where it matters: untrusted PRs can't mutate, mutation gated to `main`, runtime can't deploy; still only ~3 working roles; $0; matches ADR-0009's "plan on PR / apply on main" intent | A few roles + trust policies to author and keep scoped; the `sub` trust condition must be pinned correctly (a wildcard here is the real footgun) |
| **Single all-powerful role for CI + runtime** | Simplest possible; one thing to reason about | Worst blast radius — one leaked trust condition or bad `apply` = full account; untrusted PR code runs with write; no separation between "build" and "run" identities |
| **Per-service / per-resource roles from day one** | Minimal blast radius per resource; textbook least privilege | Role/policy sprawl with no real safety gain at one-app scale; high maintenance for a solo maintainer; the over-engineering trap this project explicitly avoids |

## Consequences

- **Positive:** The whole authorization story is now one principle and ~3 real roles. Untrusted PRs get
  a **read-only** identity; mutation authority is **gated to `main`**; the running app **cannot deploy
  itself**; and there are **no static AWS credentials anywhere** — CI and runtime are both role-based,
  clients use Cognito, and the sole stored secret (RDS password) is the documented exception (ADR-0019).
  All $0.
- **Negative / tradeoffs:** More than one CI role means more trust policies to author, and the
  `token.actions.githubusercontent.com:sub` condition on `tf-apply` **must** be pinned to the repo +
  `refs/heads/main` — a loose `StringLike` wildcard here silently reopens the whole thing, so it needs a
  review checklist item. Keeping IAM-write out of `tf-apply` while still letting Terraform manage most
  infra is a known seam (some IAM changes may need the bootstrap path). "One shared execution role" will
  eventually need splitting; we accept deferring that until policies genuinely diverge.
- **Follow-ups:**
  - ADR-0009 (defines the OIDC role this refines into `tf-plan`/`tf-apply`), ADR-0007 (consumes the CI
    role; Fargate task role), ADR-0019 (runtime SSM read is the exec role's main grant), ADR-0016/0015
    (Cognito is the client boundary), ADR-0002 (RDS connect grant), ADR-0012 (this is the IAM slice of
    the security posture).
  - Terraform: split the current single deploy role into `tf-plan`/`tf-apply` with distinct trust
    policies; add a review check that the `apply` role's `sub` condition is pinned to `main`.
  - Document the bootstrap-vs-main state split (what admin-creates-once vs. what CI manages).
  - **Escalation not taken yet:** RDS **IAM database authentication** (short-lived token via the exec
    role instead of the SSM-stored password) would remove the last stored secret — deferred because
    ADR-0019 just standardized SSM `SecureString` and IAM-auth token refresh adds connection-pool
    plumbing on long-lived Fargate connections. Revisit if removing the DB password becomes worthwhile.

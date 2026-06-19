# ADR-0016: Auth & user identity — Amazon Cognito

- **Status:** Accepted
- **Date:** 2026-06-19
- **Deciders:** Stephen Delaney
- **Tags:** application-layer, auth, identity, security

## Context

The platform needs **authentication and a canonical user identity**. This ADR is load-bearing for the
project centerpiece: identity stitching (ADR-0013) makes **Cognito's `sub` the single canonical
`user_id`** across the OLTP SoR (ADR-0002) and the behavioral domain (PostHog, ADR-0006). Auth must
mint that `sub` at signup, surface it in the **JWT** the API validates (ADR-0015), and be the value
the SPA passes to PostHog `identify` (ADR-0014/0013). Because we **own auth**, identity stitching can
be deterministic rather than probabilistic (ADR-0013).

Constraints: $0 (generous free tier); solo maintainer; no rolling our own credential storage; must
integrate with API Gateway (ADR-0015), the React SPA (ADR-0014), and Terraform (ADR-0009).

## Decision

We will use **Amazon Cognito** (User Pool) for authentication. The Cognito **`sub`** is the **one
canonical `user_id`**, minted at signup and reused verbatim in OLTP rows (ADR-0002), the JWT validated
by the API Gateway authorizer (ADR-0015), and the PostHog `distinct_id` via `identify` (ADR-0013).
The app **never invents its own user id**. Cognito is provisioned by Terraform (ADR-0009).

## Options considered

| Option | Pros | Cons |
|---|---|---|
| **Amazon Cognito (chosen)** | $0 free tier; managed signup/login/JWT/MFA — no credential storage to own; native API Gateway JWT authorizer (ADR-0015); `sub` is a stable canonical key (exactly what ADR-0013 needs); Terraform-provisioned; stays in-AWS | Cognito DX/UX is rough (hosted UI dated; some sharp edges); migrating user pools later is painful; provider lock-in for the auth layer |
| Auth0 / Clerk (managed) | Excellent DX/UX, fast to integrate | Free tiers exist but MAU-capped and a separate vendor/control plane; leaves the AWS+Terraform story; potential cost at scale |
| Roll our own (Postgres + JWT) | Full control, no vendor | Owns password storage, reset, MFA, security — **a liability**, not a learning win worth the risk for a solo project; reinvents a solved problem |
| Supabase Auth | Good DX, free tier | Pulls auth (and gravity) toward Supabase, away from the AWS/RDS/Terraform stack we're deliberately building |

## Consequences

- **Positive:** Managed, $0 auth with MFA and JWTs we don't have to secure ourselves. **`sub` as the
  canonical `user_id`** makes the whole two-domain identity-stitching design (ADR-0013) deterministic
  and testable — one key minted once, reused in OLTP, JWT, and PostHog. Native API Gateway authorizer
  (ADR-0015) and Terraform provisioning (ADR-0009) keep it in-stack.
- **Negative / tradeoffs:** Cognito's developer/hosted-UI experience is **rough** — we accept some
  integration friction (likely a custom React auth UI on Cognito, ADR-0014). **User-pool lock-in**:
  migrating off Cognito later is real work, so `sub` becomes a key we're committed to — which is fine,
  it's the canonical id by design. Token handling (storage, refresh, `reset` on logout) is the SPA's
  responsibility (ADR-0014/0013).
- **Follow-ups:** ADR-0013 (confirms `sub` is the surfaced key in JWT + OLTP — this ADR satisfies that
  follow-up), ADR-0015 (Cognito JWT authorizer), ADR-0014 (SPA auth UI + token lifecycle + `reset`),
  ADR-0006 (`identify(sub)` wiring), ADR-0009 (Terraform: User Pool + app client + authorizer),
  ADR-0012 (auth on the request-path security/golden-signal posture).

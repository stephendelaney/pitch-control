# ADR-0014: Web app — React SPA on S3 + CloudFront

- **Status:** Accepted
- **Date:** 2026-06-19
- **Deciders:** Stephen Delaney
- **Tags:** experience-layer, frontend, infra, web

## Context

The full-project scope (STATUS) includes an **experience layer**: a web app where managers sign up,
pick squads, set lineups, and make transfers. This UI is the **source of both operational events**
(writes to the OLTP SoR via the API, ADR-0015/0002) **and behavioral events** (PostHog, ADR-0006) —
it is where identity stitching begins, calling `identify(<Cognito sub>)` / `reset()` (ADR-0013/0016).
We need a way to build and **host a web frontend at $0** with no always-on server.

Constraints: $0 / no standing compute; solo maintainer; must integrate Cognito auth (ADR-0016), call
the API (ADR-0015), and emit PostHog events (ADR-0006); provisioned by Terraform (ADR-0009).

## Decision

We will build a **React single-page app**, hosted as **static assets in S3 served via CloudFront**.
CloudFront is load-bearing, not just a CDN: raw S3 static-website hosting is **HTTP-only and requires
a public bucket** — both non-starters for an authed app handling Cognito tokens. CloudFront gives
**HTTPS/TLS on a custom domain** (free ACM cert) and a **private bucket via Origin Access Control**
(only CloudFront can read S3); edge caching, HTTP/2/3, and the **SPA routing fallback to `index.html`**
(map 403/404 → `index.html` 200) are the bonus on top. It authenticates against Cognito (ADR-0016),
calls the API Gateway backend (ADR-0015), and emits PostHog events with `identify`/`reset` on the auth
lifecycle (ADR-0013/0006). There is **no server-side rendering and no always-on web server**.

## Options considered

| Option | Pros | Cons |
|---|---|---|
| **React SPA on S3 + CloudFront (chosen)** | $0 (S3 static + CloudFront free tier); no server to run; **HTTPS/TLS on a custom domain (raw S3 hosting is HTTP-only)**; **private S3 bucket via OAC (raw S3 hosting needs a public bucket)**; global CDN caching; clean split from the API (ADR-0015); React is the conventional skill to learn; Terraform-provisioned (ADR-0009) | SPA-only (no SSR/SEO) — fine for an authed app; CloudFront cache invalidation on deploy to manage; client-side auth/token handling care |
| Next.js (SSR) on Lambda/Amplify | SSR/SEO, great DX | Wants server runtime (SSR) — more infra/cost than static; SEO irrelevant behind login; over-scoped |
| AWS Amplify Hosting | Turnkey CI + hosting | More managed/opaque; ties hosting to Amplify; less hands-on infra learning than S3+CloudFront+Terraform |
| Server-rendered app (FastAPI templates) | One backend, no SPA build | Couples UI to API; misses the SPA/CDN learning goal; heavier request path for an interactive app |
| Vercel/Netlify free | Excellent DX, free tier | Another control plane outside AWS; splits infra from the Terraform/AWS story we're building |

## Consequences

- **Positive:** $0 static hosting with a global CDN and TLS, no server to run. Clean experience/API
  separation (ADR-0015). The SPA is the natural home for the `identify`/`reset` calls that anchor
  identity stitching (ADR-0013). React on S3+CloudFront via Terraform is a strong, conventional
  full-stack + infra learning surface (roadmap Wk 1+).
- **Negative / tradeoffs:** No SSR/SEO — acceptable for an authenticated game UI. CloudFront cache
  invalidation and SPA-route fallback need config. Client-side auth means careful Cognito token
  handling (storage, refresh) — owned in ADR-0016. Build/deploy pipeline (CI → S3 sync → invalidate)
  is ours to wire (ADR-0007/0009).
- **Follow-ups:** ADR-0015 (the API it calls), ADR-0016 (Cognito auth + token handling), ADR-0006
  (PostHog SDK wiring), ADR-0013 (`identify`/`reset` hooks), ADR-0009 (Terraform: S3 bucket +
  CloudFront + invalidation), ADR-0012 (front-end golden-signal SLIs on the request path).

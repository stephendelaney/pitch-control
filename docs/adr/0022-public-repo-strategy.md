# ADR-0022: Public-repo strategy — build in public + Pages showcase, gated by secret/PII leakage controls

- **Status:** ✅ Accepted (ratified 2026-07-04)
- **Date:** 2026-07-04
- **Deciders:** Stephen Delaney
- **Tags:** repo-governance, security, docs, ci-cd

## Context

The repo is public (**[stephendelaney/pitch-control](https://github.com/stephendelaney/pitch-control)**)
and its strongest asset is the **visible process**: the ADR log, `docs/STATUS.md` discipline,
readable `infra/`, SLOs/runbooks. That "here is the rationale *and* the physical implementation" story
is the differentiated portfolio signal — rarer and more credible than a polished end-artifact alone.

The question raised: move the *code* into a **private** repo and reveal a **finished product + guide**
in the public repo at the end. The stated motivation is **secret/PII leakage** — a general discomfort
with any exposure. Two facts reframe that:

1. **The 1Password vault is not exposed via GitHub.** ADR-0019 keeps secrets off disk — the `op` CLI
   reads them at runtime; Lambdas read SSM `SecureString`. Nothing secret is *supposed* to be in the
   tree. So a private repo does not reduce the vault's exposure; it is already zero.
2. **The real risk is the mundane accident** — a pasted token, a stray `.env`, a `terraform.tfvars`
   with a real value, or ingested FPL data (Stephen's own manager entry = PII) landing in a commit.
   On a **public** repo, any such commit must be treated as **indexed and compromised the instant it is
   pushed**; deleting it later does not undo that. The whole game is **prevention before the fact.**

The risk surface is **near-zero today** (Wk 1 = infra + docs; nothing sensitive) and **opens at Wk 2**
(ADR-0010/0021 dlt pulls real FPL data; the DB password lands in the runner env). So a gate installed
now, at a clean boundary, is a prerequisite rather than a Wk-2 retrofit.

Constraints: solo maintainer, learning goals, free-tooling/credits-plan cost posture, and the
observation above that **the in-progress journey is the asset** — hiding it trades the rare signal for
the common one. Related: ADR-0019 (secrets), ADR-0009/0020 (OIDC/IAM), ADR-0014 (S3+CloudFront — the
site-hosting muscle memory, though Pages is used here for the showcase).

## Decision

We will **stay public and build in public.** At the end we **layer** a curated **GitHub Pages (Jekyll)
showcase + guide** on top of the intact repo — a polished "finished product" entry point that does not
hide the journey underneath it. This is **enabled by a defense-in-depth secret/PII leakage gate landed
before Wk 2**, not by moving code private: (1) `.gitignore` for env/secret/data artifacts *(already in
place)*; (2) a **pre-commit** local gate — `gitleaks` + `detect-private-key` + `check-added-large-files`;
(3) **GitHub secret scanning + push protection** (free on public repos) as the server-side backstop;
(4) a **CI `gitleaks` scan** folded into the planned fmt/validate workflow (backlog B5); (5) a
**leak-response runbook** (rotate-first, then purge history); (6) a **PII convention** — synthetic
fixtures only, Stephen's own FPL entry never committed (it lives in S3/DuckDB, both git-ignored).

## Options considered

| Option | Pros | Cons |
|---|---|---|
| **A (chosen): stay public, build in public, Pages showcase at the end, secret/PII gate** | Keeps the rare asset — visible rationale→implementation with granular history; showcase is *added*, not traded for; one repo, no sync tax; gate is good practice under any strategy; leverages Stephen's existing Jekyll/YAML-frontmatter comfort | Requires disciplined guardrails *before* sensitive code lands (this ADR's gate); the polished reveal is extra end-of-project work; zero tolerance for a leaking commit (mitigated by layers 2–5) |
| B: code private, reveal finished product + guide at end | Feels safest to the leakage instinct; full narrative control of the reveal | Hides the differentiated asset (process + granular history); **reveal-never-lands** failure mode (solo multi-week projects rarely hit a crisp "done"; public repo goes stale/vaporware-looking); **code/infra boundary is fuzzy** — Terraform/dbt/dlt are already public and load-bearing to the docs; squash-on-reveal destroys the history that *is* the evidence; does **not** actually reduce vault exposure (already zero per ADR-0019) |
| C: private dev/scratch branch, merge polished slices to public | Hides messy exploration without going fully dark; targeted | Sync overhead; still risks a secret entering the *private* branch then being merged forward — doesn't remove the need for the layer-2/3 gate, so it adds cost without removing the real control |

## Consequences

- **Positive:** the repo keeps its strongest signal (process + implementation, public, with history)
  and *gains* a polished Pages entry point at the end. Security posture moves from
  "`.gitignore` + good intentions" to **enforced defense-in-depth** with a server-side backstop that
  holds even if a local hook is skipped. Installed at a clean boundary, the gate is in place *before*
  the first sensitive commit (Wk 2), which is the only time prevention is cheap.
- **Negative / tradeoffs:** we accept that a public repo has **zero tolerance** for a leaking commit and
  own the guardrails that enforce it (a bypassed hook + a public-repo push-protection gap would be the
  hole — hence the CI scan as a third layer). The end-of-project showcase is real extra work we are
  deferring, not free. We are *not* getting the "hide unfinished code" comfort of option B — by design,
  because the unfinished-but-disciplined state is the point.
- **Follow-ups:** (1) `.pre-commit-config.yaml` + `docs/runbooks/secret-leak-response.md` land with this
  ADR *(this session)*. (2) Backlog **B10** tracks the gate rollout; **B5** absorbs the CI `gitleaks`
  job. (3) Manual, Stephen-run: `pre-commit install`; enable **push protection** (repo Settings → Code
  security & analysis). (4) The Pages/Jekyll showcase + guide is a **Wk-5+ roadmap** item, built over the
  intact repo. (5) CLAUDE.md gains a one-line house rule pointing here.

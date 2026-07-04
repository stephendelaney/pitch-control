# Runbook: secret / PII committed to the public repo

- **Severity:** SEV1 (credential or PII exposed on a public repo — treat as live compromise)
- **Affected SLI(s):** n/a (security incident, not a data-pipeline SLI)

## Symptom

A secret value (DB password, API token, private key) or PII (a real user/manager entry, an email)
has been **committed** — and possibly **pushed** — to the public repo. Surfaced by a GitHub secret-
scanning alert, a `gitleaks` CI failure, push-protection blocking a push, or a manual spot.

## Detection

- GitHub **secret scanning** alert (Settings → Code security & analysis) or **push protection** block.
- **CI `gitleaks` scan** failing on a PR (backlog B5), or the local `.pre-commit-config.yaml` gate
  firing before commit (ADR-0022 — the ideal case: caught pre-commit, nothing to remediate).
- Manual discovery in the diff/history.

## Golden rule

**Public = assume indexed the instant it was pushed.** Purging history does **not** un-leak a secret —
crawlers, forks, and caches may already have it. So the order is **rotate first, purge second.** Never
reverse it.

## Remediation

1. **Rotate the exposed credential *first*** — before touching git history.
   - DB password: generate a new one, update **1Password** (`op://pitch-control/rds-master/password`),
     then `terraform apply` / rotate on RDS so the leaked value is dead.
   - Any token/API key: revoke + reissue at the provider; update 1Password and the SSM `SecureString`
     it seeds (ADR-0019).
   - Confirm the old value no longer authenticates anywhere.
2. **If it was only committed locally, not pushed** — the leaked value must *still* be rotated if it is
   a real secret (it hit your disk/history), but history surgery is simple: `git reset` / amend the
   commit out before pushing. Verify with `git log -p` that it's gone, then proceed.
3. **If it was pushed** — purge it from history:
   - Prefer **`git filter-repo`** (`brew install git-filter-repo`):
     `git filter-repo --path <leaked-file> --invert-paths` (whole file), or
     `--replace-text <patterns.txt>` (value only, `LEAKED==>REDACTED`).
   - Then **force-push** the rewritten history: `git push --force-with-lease origin main`.
   - Note: this rewrites SHAs — a solo repo makes this cheap; anyone with a fork/clone still has the old
     history, which is *why step 1 (rotation) is what actually protects you.*
4. **Invalidate caches where possible** — for a GitHub secret-scanning alert, mark it resolved only
   after rotation. Consider contacting GitHub Support to purge cached views of the specific commit if
   the secret is high-value.
5. **PII (no credential to rotate):** same history purge (steps 2–3). There is no "rotate" — the
   exposure is the harm — so the emphasis shifts to (a) confirming what/whose data leaked and (b)
   tightening the fixture/data convention so it can't recur (Prevention).

## Prevention

- **Local gate:** `.pre-commit-config.yaml` (`gitleaks` + `detect-private-key` + `check-added-large-files`)
  — install with `pre-commit install` (ADR-0022). This is the layer that stops it *before* the commit.
- **Server backstop:** enable **secret scanning + push protection** (free on public repos) so a skipped
  local hook still can't push a detected secret.
- **CI backstop:** `gitleaks` full-scan job in the fmt/validate workflow (backlog B5).
- **PII convention (ADR-0022):** test fixtures are **synthetic only**; Stephen's own FPL entry is never
  committed — real ingested data lives in S3/DuckDB, both git-ignored.
- **Secrets posture (ADR-0019):** nothing secret is *supposed* to be in the tree — `op` at runtime, SSM
  `SecureString` for Lambdas. If a value is in a file, that itself is the bug.

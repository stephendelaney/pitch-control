# Runbook: Bronze load failure (FPL → S3)

- **Severity:** SEV2 (pipeline down) — escalates to SEV3 only if a later gameweek load also fails
- **Affected SLI(s):** Freshness, Completeness

## Symptom

The scheduled `ingest-fpl-bronze` job is red, or `ops.pipeline_runs` shows the Bronze stage with
`status = 'failed'` / no row for today.

## Detection

- GitHub Actions failure notification, **or**
- Healthchecks.io dead-man's-switch fires (no success ping), **or**
- Freshness SLO breach on the Ops dashboard.

## Diagnosis

1. Open the failed GitHub Actions run; read the `dlt` step logs.
2. Classify the failure:
   - **HTTP 429 / 503 from FPL** — unofficial API rate-limited or briefly down. Most common.
   - **Schema change** — FPL added/renamed a field; dlt schema contract rejected it.
   - **AWS auth / S3** — OIDC role or bucket policy issue (check after any `infra/` change).
3. Confirm the source manually: `curl -s https://fantasy.premierleague.com/api/bootstrap-static/ | jq '.elements | length'`.

## Remediation

- **Rate-limit / transient:** re-run the job. Loads are append-only and idempotent per run date,
  so a re-run is safe and backfills the gap.
- **Schema change:** inspect the new field, update the dlt schema/contract, land it in Bronze raw
  (JSONB tolerates the new key), then re-run. Open an ADR if the change affects Silver modeling.
- **AWS auth:** re-check the OIDC trust policy / bucket policy in `infra/`; `terraform plan` to spot drift.

## Prevention

- dlt schema contract set to `evolve` for Bronze (tolerate new columns), `freeze` for Silver.
- Polite client: backoff + jitter, max 1 req/sec to FPL.
- elementary volume test on the Bronze players table to catch silent partial loads.

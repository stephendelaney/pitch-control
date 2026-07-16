# Runbook: orphaned ephemeral SG ingress rule (CI ingest)

- **Severity:** SEV2 (security posture degraded — 5432 exposed to a stale /32 beyond home)
- **Affected SLI(s):** n/a (security/config incident, not a data-pipeline SLI)

## Symptom

The RDS security group holds an ephemeral CI ingress rule that should have been revoked when the
run finished. The rule allows 5432 from a GitHub-hosted runner's /32 that is **no longer in use** —
and Azure recycles those addresses, so the /32 now belongs to someone else.

This is the accepted cleanup failure mode of **[ADR-0021](../adr/0021-ci-ingest-network-path.md)**:
the ingest workflow authorizes the runner's own IP, runs dlt, and revokes via `if: always()`. A
hard-killed runner (cancelled job, spot reclaim, OOM) skips the revoke.

## Detection

- **Scheduled janitor** (ADR-0021) fails or reports rules older than its threshold.
- **Start-of-run sweep** in the ingest workflow logs a rule it did not create.
- Manual audit — list every ephemeral rule on the RDS SG:
  ```
  aws ec2 describe-security-group-rules \
    --filters "Name=group-id,Values=sg-0bdc782c110aa0ba0" \
    --query 'SecurityGroupRules[?!IsEgress && contains(Description, `ci-ingest-ephemeral`)].{id:SecurityGroupRuleId,cidr:CidrIpv4,desc:Description}' \
    --output table
  ```

> **Convention this depends on:** the ingest workflow must stamp every rule it creates with a
> description of `ci-ingest-ephemeral run=<github.run_id>` and tags
> `ManagedBy=ci-ingest`, `RunId=<github.run_id>`, `CreatedAt=<ISO8601>`. Detection here is *by
> that stamp* — an unstamped rule is either Stephen's home /32 (Terraform-managed, leave it) or
> something unexplained (investigate, don't blind-revoke).

## Diagnosis

1. **Confirm the rule is actually orphaned, not live.** Read `RunId` off the rule, then check
   whether that run is still going:
   ```
   gh run view <RunId> -R stephendelaney/pitch-control --json status,conclusion
   ```
   `status: in_progress` ⇒ **not orphaned** — a concurrent ingest run legitimately owns it. Stop.
2. **Establish exposure window** — `CreatedAt` tag vs now. This is how long 5432 has been reachable
   from an address the project no longer controls.
3. **Check whether the exposure was used.** The window is what matters, not the rule:
   ```
   aws rds describe-db-log-files --db-instance-identifier pitch-control-pg
   ```
   Postgres rejects non-TLS (`rds.force_ssl=1`) and requires the `pitchadmin` password from
   1Password, so a scan lands on auth failures — but confirm no successful session from an
   unexpected host in the window before closing this out.

## Remediation

1. **Revoke the rule** (by rule id, from Detection):
   ```
   aws ec2 revoke-security-group-ingress \
     --group-id sg-0bdc782c110aa0ba0 \
     --security-group-rule-ids <sgr-…>
   ```
2. **Verify the SG is back to just the Terraform-managed rules** — re-run the Detection query; it
   should return empty. Cross-check against `allowed_cidrs`:
   ```
   cd infra && terraform plan
   ```
   **Expect "no changes" either way — that is not proof of cleanup.** `network.tf` manages ingress
   as discrete `aws_vpc_security_group_ingress_rule` resources (not inline `ingress` blocks on the
   SG), so a rule Terraform never created is invisible to it. Terraform will **not** revoke an
   orphan for you. The Detection query is the check that counts.
3. **If diagnosis found a successful unexpected session:** this is a credential compromise, not a
   config cleanup — rotate the RDS master password per
   [`secret-leak-response.md`](secret-leak-response.md) (rotate first), then continue here.

## Prevention

- **`if: always()` revoke** on the ingest workflow — the first line of defence (ADR-0021).
- **Start-of-run sweep** — each ingest run revokes any `ci-ingest-ephemeral` rule whose `RunId` is
  not an in-progress run, before opening its own. Self-healing on the next scheduled run.
- **Scheduled janitor** — a cron workflow running the same sweep, so cleanup does not depend on a
  *subsequent ingest run happening*. This is what bounds the exposure window when ingest is paused.
- **Narrow IAM** — the SG grant/revoke policy is resource-scoped to this one SG and lives on the
  runtime ingest role, never `tf-apply` (ADR-0020).
- **End-state** — the orphan class disappears when the ADR-0015 API Lambdas land in-VPC and this job
  migrates to SG-to-SG ingress (ADR-0021 option B). No IP games, nothing to leak, nothing to sweep.

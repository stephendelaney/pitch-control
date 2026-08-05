#!/usr/bin/env bash
# ADR-0021's ephemeral security-group ingress, in one place.
#
# The Postgres->Bronze job runs on a GitHub-hosted runner whose IP is unpredictable, and RDS is
# public but IP-locked. So the job opens 5432 to its own /32, runs, and closes it again. That
# is a data job mutating security config; the mitigation for how ugly that is, is that the
# mutation is small, stamped, and swept.
#
#   open    authorize this runner's /32 on 5432, stamped with the run that owns it
#   close   revoke the rule this run opened (safe to call when open never ran)
#   sweep   revoke any stamped rule whose owning run is no longer in progress
#
# `sweep` lives here rather than in the workflow because two callers need it to behave
# identically: the ingest job (start-of-run, self-healing) and the scheduled janitor (which is
# what bounds the exposure window when ingest is paused). Duplicating the stamping convention
# across two YAML files is how the janitor quietly stops matching what the opener writes.
#
# The convention itself is prescribed by docs/runbooks/orphaned-sg-rule.md — the runbook
# detects orphans *by this stamp*, so the two must agree. An unstamped rule is Stephen's home
# /32 from Terraform: never touched here.
set -euo pipefail

SG_NAME_TAG="${SG_NAME_TAG:-pitch-control-rds}"
PORT="${PORT:-5432}"
RULE_DESCRIPTION_PREFIX="ci-ingest-ephemeral"
MANAGED_BY="ci-ingest"

# Where `open` records the rule it created so `close` can revoke that exact rule rather than
# re-deriving it. $RUNNER_TEMP is per-job and discarded with the runner.
RULE_ID_FILE="${RULE_ID_FILE:-${RUNNER_TEMP:-/tmp}/sg-ephemeral-rule-id}"

log() { echo "  $*"; }
die() { echo "::error::$*" >&2; exit 1; }

# `name_prefix` + `create_before_destroy` in infra/network.tf means the SG id changes if the
# group is ever replaced. Resolving by the Name tag keeps this correct across that, and fails
# loudly rather than silently opening a hole on some other group.
resolve_sg_id() {
  local sg_id
  sg_id="$(aws ec2 describe-security-groups \
    --filters "Name=tag:Name,Values=${SG_NAME_TAG}" \
    --query 'SecurityGroups[].GroupId' --output text)"

  [ -n "$sg_id" ] && [ "$sg_id" != "None" ] || die "no security group tagged Name=${SG_NAME_TAG}"
  # More than one match means the tag is ambiguous; opening 5432 on a guess is not acceptable.
  [ "$(wc -w <<<"$sg_id")" -eq 1 ] || die "tag Name=${SG_NAME_TAG} matches several groups: ${sg_id}"

  echo "$sg_id"
}

runner_ip() {
  local ip
  ip="$(curl -sS --max-time 10 https://checkip.amazonaws.com | tr -d '[:space:]')"
  # Validated because this string goes straight into a security-group rule. A proxy error page
  # or an empty body must fail here, not become a malformed (or worse, over-broad) CIDR.
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "could not determine runner IP (got: '${ip}')"
  echo "$ip"
}

cmd_open() {
  local sg_id ip cidr description created_at rule_id
  sg_id="$(resolve_sg_id)"
  ip="$(runner_ip)"
  cidr="${ip}/32"
  description="${RULE_DESCRIPTION_PREFIX} run=${GITHUB_RUN_ID}"
  created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  log "opening ${cidr} on ${PORT}/tcp of ${sg_id} (run ${GITHUB_RUN_ID})"

  # Built with jq rather than the CLI's shorthand syntax: the description contains a space,
  # and shorthand quoting around that is a known way to end up with a rule whose description
  # is silently truncated — which would make it invisible to the runbook's orphan query.
  rule_id="$(aws ec2 authorize-security-group-ingress \
    --group-id "$sg_id" \
    --ip-permissions "$(jq -nc \
      --arg cidr "$cidr" --arg desc "$description" --argjson port "$PORT" \
      '[{IpProtocol:"tcp",FromPort:$port,ToPort:$port,IpRanges:[{CidrIp:$cidr,Description:$desc}]}]')" \
    --tag-specifications "$(jq -nc \
      --arg managed "$MANAGED_BY" --arg run "$GITHUB_RUN_ID" --arg created "$created_at" \
      '[{ResourceType:"security-group-rule",Tags:[
           {Key:"ManagedBy",Value:$managed},
           {Key:"RunId",Value:$run},
           {Key:"CreatedAt",Value:$created}]}]')" \
    --query 'SecurityGroupRules[0].SecurityGroupRuleId' --output text)"

  [ -n "$rule_id" ] && [ "$rule_id" != "None" ] || die "authorize returned no rule id"

  echo "$rule_id" >"$RULE_ID_FILE"
  log "rule ${rule_id} created — recorded at ${RULE_ID_FILE}"
}

cmd_close() {
  local sg_id rule_id
  # Absent file = `open` never ran (an earlier step failed first). Closing is wired to
  # `if: always()`, so this path is normal and must not turn a real failure into two.
  if [ ! -s "$RULE_ID_FILE" ]; then
    log "no ephemeral rule recorded for this run — nothing to revoke"
    return 0
  fi

  rule_id="$(cat "$RULE_ID_FILE")"
  sg_id="$(resolve_sg_id)"
  log "revoking ${rule_id} from ${sg_id}"

  # Not fatal on failure: the sweep and the janitor are the backstop, and failing the job here
  # would report the *load* as broken when the load succeeded. It is still an error-level log
  # so it is visible, and the rule is still stamped for the runbook to find.
  if aws ec2 revoke-security-group-ingress \
      --group-id "$sg_id" --security-group-rule-ids "$rule_id" >/dev/null; then
    rm -f "$RULE_ID_FILE"
    log "revoked"
  else
    echo "::error::failed to revoke ${rule_id} — see docs/runbooks/orphaned-sg-rule.md" >&2
  fi
}

# Is the run that owns a rule still going? A concurrent run legitimately owns its own rule, and
# revoking it would break a healthy job. `gh` needs `actions: read` on the calling workflow.
run_is_in_progress() {
  local run_id="$1" status
  status="$(gh run view "$run_id" --repo "$GITHUB_REPOSITORY" --json status --jq .status 2>/dev/null || true)"
  # An unresolvable run id (deleted, or from a log-retention-expired run) reads as not
  # in-progress. That biases toward revoking, which is the right way to be wrong: the cost is
  # a job that fails loudly and retries, versus 5432 left open to an address we do not own.
  [ "$status" = "in_progress" ] || [ "$status" = "queued" ]
}

cmd_sweep() {
  local sg_id rules count=0 failed=0
  sg_id="$(resolve_sg_id)"

  # Selected by the ManagedBy tag, not by description text: the tag is what the runbook keys
  # off, and it is the one field a partially-applied rule cannot have without CreateTags.
  rules="$(aws ec2 describe-security-group-rules \
    --filters "Name=group-id,Values=${sg_id}" \
    --query "SecurityGroupRules[?!IsEgress && Tags[?Key=='ManagedBy' && Value=='${MANAGED_BY}']].[SecurityGroupRuleId, Tags[?Key=='RunId']|[0].Value, Tags[?Key=='CreatedAt']|[0].Value]" \
    --output text)"

  if [ -z "$rules" ]; then
    log "no ephemeral rules on ${sg_id} — nothing to sweep"
    return 0
  fi

  while read -r rule_id run_id created_at; do
    [ -n "$rule_id" ] || continue

    if [ "$run_id" = "${GITHUB_RUN_ID:-}" ]; then
      log "keeping ${rule_id} — owned by this run"
      continue
    fi

    if run_is_in_progress "$run_id"; then
      log "keeping ${rule_id} — run ${run_id} is still in progress"
      continue
    fi

    # Worth an ::warning:: rather than a quiet log line: reaching here means an earlier run's
    # `always()` revoke did not happen, which is the SEV2 in the runbook. The sweep fixes the
    # exposure, but the fact that it had to is the signal.
    echo "::warning::revoking orphaned rule ${rule_id} from run ${run_id} (created ${created_at}) — see docs/runbooks/orphaned-sg-rule.md"

    # Guarded rather than bare, because `set -e` would otherwise abort the whole loop on the
    # first failure — leaving every *remaining* orphan open. That inverts the job: one rule
    # that cannot be revoked (a race with another sweep, a throttled API call) would silently
    # cost us the cleanup this workflow exists to perform, and the failed job would look like
    # a single problem rather than N open holes.
    #
    # So: keep going, and still fail at the end. Neither half is optional — continuing without
    # failing would hide the exposure, failing without continuing would widen it.
    if aws ec2 revoke-security-group-ingress \
        --group-id "$sg_id" --security-group-rule-ids "$rule_id" >/dev/null; then
      count=$((count + 1))
    else
      echo "::error::failed to revoke orphaned rule ${rule_id} from run ${run_id} — see docs/runbooks/orphaned-sg-rule.md" >&2
      failed=$((failed + 1))
    fi
  done <<<"$rules"

  log "swept ${count} orphaned rule(s)"
  [ "$failed" -eq 0 ] || die "${failed} orphaned rule(s) could not be revoked — 5432 may still be open"
}

case "${1:-}" in
  open)  cmd_open ;;
  close) cmd_close ;;
  sweep) cmd_sweep ;;
  *)     die "usage: $(basename "$0") open|close|sweep" ;;
esac

#!/usr/bin/env python3
"""Append a pipeline run record to the lake — ADR-0025's writer.

    ops_ledger.py start  --pipeline fpl_bronze
    ops_ledger.py finish --pipeline fpl_bronze --status "$JOB_STATUS" [--metrics FILE]

Two records per run, never one. The pair is what carries liveness: a job that is hard-killed
mid-flight writes a `start` and no `finish`, so "died without saying so" is a *missing* record
rather than a row stuck in `status = 'running'` that nobody ever updates. There is no UPDATE
path in an object store and this design does not want one — Bronze is append-only (ADR-0003)
and the ledger obeys the same rule as every other thing that lands there.

Both records carry the same `run_key`, which is the join key Silver pairs them on.

Why this lives in `.github/scripts/` rather than in `ingest/` or `transform/`: three jobs across
two Python environments write these records, and the environments do not share a requirements
file. The same argument that put `sg-ephemeral.sh` here applies — the writers must not be able
to drift apart on the record schema, so there is exactly one definition of it. That constraint
is also why this module is **stdlib-only** and uploads through the `aws` CLI (preinstalled on
GitHub runners) instead of boto3: `transform/requirements.txt` holds dbt and DuckDB and nothing
else, and adding an AWS SDK to it just to log that a build ran is the wrong trade.

Local runs write to a directory instead of S3 — same `PITCH_CONTROL_LAKE_BUCKET` switch the two
dlt entrypoints use, so nothing about this needs AWS to be exercised.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path

# `ops_runs` is a sibling of `fpl/` and `postgres/` under `bronze/` — a source in its own right,
# because that is what it is: records produced by the platform's own jobs. It is deliberately
# NOT `bronze/postgres/ops_pipeline_runs/`, which is the dlt snapshot of the RDS table of a
# similar name. ADR-0025 separates the two: RDS `ops.pipeline_runs` belongs to the app layer,
# this belongs to CI, and they must not be confused for one another in Silver.
LEDGER_PREFIX = "bronze/ops_runs"

# Hive-style, matching every other Bronze path (ADR-0003/0004) so DuckDB reads `load_date` as a
# real column and Silver can prune to a date range instead of scanning every run ever recorded.
LAYOUT = "{prefix}/load_date={date}/{run_key}.{event}.jsonl"

# The workflow passes GitHub's own `job.status`, whose vocabulary is not the ledger's. Cancelled
# is folded into `failed` on purpose: from the SLI's point of view (ADR-0012) a cancelled run
# did not produce data, and inventing a third terminal state would mean every consumer has to
# decide what it means. The distinction is not lost — `detail.job_status` keeps the original.
STATUS_MAP = {
    "success": "success",
    "failure": "failed",
    "failed": "failed",
    "cancelled": "failed",
    "canceled": "failed",
}

# A metrics file may only set these. An allowlist rather than a blind merge because the file is
# written by a different program than the one that reads it — a typo'd key should surface as a
# warning here, not as a column that silently never populates in the mart.
METRIC_FIELDS = ("rows_processed", "peak_mem_mb", "error", "detail")

# Set this to pair the two records of a run that GitHub is not identifying for us — a local
# rehearsal, or any future caller outside Actions. In CI it is unnecessary and unset.
ENV_RUN_KEY = "PITCH_CONTROL_LEDGER_RUN_KEY"


def utcnow() -> datetime:
    return datetime.now(timezone.utc)


def sanitise(value: str) -> str:
    """Reduce a value to what is safe in an S3 key segment and in a Hive path.

    A hyphen is a legal output character but not an input one, so a run of separators collapses
    to a single `-` instead of being preserved verbatim. Without that, a job named
    `dbt build -> Silver` yields `dbt-build---Silver`: still a valid key, but the kind of thing
    that gets "tidied" later by someone who assumes it was an accident.
    """
    return re.sub(r"[^A-Za-z0-9._]+", "-", value).strip("-") or "unknown"


def run_identity() -> tuple[dict[str, object], list[str]]:
    """Describe *where* this run happened, from the environment GitHub provides.

    Off a runner every one of these is absent, so the run gets a synthetic key and
    `runtime = "local"`. That matters downstream: a maintainer's laptop build should be
    distinguishable from a scheduled one in the mart rather than quietly inflating the
    success rate of the unattended schedule, which is the thing the SLO is actually about.
    """
    run_id = os.environ.get("GITHUB_RUN_ID")
    attempt = os.environ.get("GITHUB_RUN_ATTEMPT") or "1"
    job = os.environ.get("GITHUB_JOB") or "local"
    repository = os.environ.get("GITHUB_REPOSITORY")
    server = os.environ.get("GITHUB_SERVER_URL") or "https://github.com"
    notes: list[str] = []

    # An explicit key wins over everything. This is what makes a local run pairable at all, and
    # it is also the escape hatch if a future caller needs to record a run GitHub did not host.
    override = os.environ.get(ENV_RUN_KEY)

    if override:
        run_key = override
        runtime = "github-actions" if run_id else "local"
        run_url = f"{server}/{repository}/actions/runs/{run_id}" if run_id and repository else None
    elif run_id:
        # run_id alone is not unique per record: `ingest-bronze` runs two jobs under one id, and
        # a re-run reuses the id with a new attempt. All three parts are needed.
        run_key = f"{run_id}.{attempt}.{job}"
        runtime = "github-actions"
        run_url = f"{server}/{repository}/actions/runs/{run_id}" if repository else None
    else:
        # Nothing here is stable across two invocations of this script, so `start` and `finish`
        # would each mint their own key and the pair would never join. Caught by rehearsing the
        # local path end to end (2026-08-08) — in CI it cannot happen, which is exactly why it
        # would have survived to become a puzzle later. Unique-per-invocation is kept because
        # the alternative (two local runs colliding on one key) is worse, and the warning is
        # what turns an invisible gap into an instruction.
        run_key = f"local.{utcnow():%Y%m%dT%H%M%S}.{uuid.uuid4().hex[:8]}"
        runtime = "local"
        run_url = None
        notes.append(
            f"no {ENV_RUN_KEY} and no GITHUB_RUN_ID - this record cannot be paired with its "
            f"other half. Export {ENV_RUN_KEY} once per run to pair local records."
        )

    return {
        "run_key": sanitise(run_key),
        "runtime": runtime,
        "run_id": run_id,
        "run_attempt": int(attempt) if attempt.isdigit() else None,
        "job": job,
        "workflow": os.environ.get("GITHUB_WORKFLOW"),
        "repository": repository,
        "git_sha": os.environ.get("GITHUB_SHA"),
        "run_url": run_url,
    }, notes


def load_metrics(path: str | None) -> tuple[dict[str, object], list[str]]:
    """Read the metrics a job left behind, tolerating its absence.

    Absence is the normal case for a job that died before it could write one, which is exactly
    when the finish record matters most — so a missing file is not an error. It is reported,
    and the record is written with nulls.
    """
    if not path:
        return {}, []

    file = Path(path)
    if not file.is_file():
        return {}, [f"metrics file not found: {path}"]

    try:
        raw = json.loads(file.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        return {}, [f"metrics file unreadable ({exc.__class__.__name__}): {path}"]

    if not isinstance(raw, dict):
        return {}, [f"metrics file is not a JSON object: {path}"]

    metrics = {key: raw[key] for key in METRIC_FIELDS if key in raw}
    unknown = sorted(set(raw) - set(METRIC_FIELDS))
    notes = [f"ignored unknown metrics key(s): {', '.join(unknown)}"] if unknown else []
    return metrics, notes


def build_record(
    event: str, pipeline: str, status: str, metrics: dict[str, object]
) -> tuple[dict, list[str]]:
    """Assemble one ledger record.

    Every field the RDS seed schema's `ops.pipeline_runs` declared is present, so the two
    ledgers stay describable by one Silver shape if the app layer's ever needs joining to this
    one — plus the run identity, which only exists here because only here is there a run to
    identify.
    """
    record = {
        "run_key": None,  # filled from run_identity below; declared first so key order reads well
        "pipeline": pipeline,
        "event": event,
        "status": status,
        "recorded_at": utcnow().isoformat(timespec="seconds"),
        "rows_processed": None,
        "peak_mem_mb": None,
        "error": None,
        "detail": None,
        "schema_version": 1,
    }
    identity, notes = run_identity()
    record.update(identity)
    record.update(metrics)
    return record, notes


def object_key(record: dict) -> str:
    return LAYOUT.format(
        prefix=LEDGER_PREFIX,
        # Partition by the date the record was *written*, not by the run's start. A run that
        # crosses midnight therefore lands its two records in different partitions; that is
        # fine because Silver pairs on `run_key`, and it keeps the partition honest about what
        # a reader will find when they prune to a date.
        date=record["recorded_at"][:10],
        run_key=record["run_key"],
        event=record["event"],
    )


def write_record(record: dict) -> tuple[str, list[str]]:
    """Put the record where it belongs, returning the destination and any problems.

    Problems are returned rather than raised. See `main` — a telemetry write must not be able
    to turn a good load red.
    """
    body = json.dumps(record, separators=(",", ":")) + "\n"
    key = object_key(record)

    bucket = os.environ.get("PITCH_CONTROL_LAKE_BUCKET")
    if not bucket:
        # Same fallback the dlt entrypoints use. The workflows assert the variable separately
        # and hard-fail on it, so this path in CI means the assertion has not run yet — worth a
        # warning, not worth a second hard guard that could only ever fire in the same breath.
        root = Path(os.environ.get("PITCH_CONTROL_LEDGER_DIR") or "_local_ledger")
        destination = root / key
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(body)
        return str(destination), ["PITCH_CONTROL_LAKE_BUCKET unset - ledger written to local disk"]

    uri = f"s3://{bucket}/{key}"
    # `-` streams stdin straight to S3: no temp file to leave on the runner, and nothing on
    # disk for a later step to read. One PutObject, which is exactly the grant the ingest and
    # transform roles hold for this prefix.
    result = subprocess.run(
        ["aws", "s3", "cp", "-", uri, "--content-type", "application/x-ndjson"],
        input=body,
        text=True,
        capture_output=True,
    )
    if result.returncode != 0:
        return uri, [f"aws s3 cp failed ({result.returncode}): {result.stderr.strip()}"]
    return uri, []


def build_argparser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Write a pipeline run record to the lake.")
    parser.add_argument("event", choices=("start", "finish"))
    parser.add_argument(
        "--pipeline",
        required=True,
        help="Logical pipeline name, e.g. fpl_bronze, postgres_bronze, transform_dbt.",
    )
    parser.add_argument(
        "--status",
        help="Terminal status for `finish`. Accepts GitHub's job.status vocabulary "
        f"({', '.join(sorted(STATUS_MAP))}). Ignored for `start`.",
    )
    parser.add_argument(
        "--metrics",
        metavar="FILE",
        help="JSON object written by the job with any of: " + ", ".join(METRIC_FIELDS),
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_argparser().parse_args(argv)

    if args.event == "start":
        status, metrics, notes = "running", {}, []
    else:
        raw_status = (args.status or "").strip().lower()
        status = STATUS_MAP.get(raw_status)
        if status is None:
            # An unrecognised status is not a reason to lose the record — a run that finished is
            # a fact worth keeping even when the caller mislabelled it. Record the failure
            # honestly instead: terminal, unsuccessful, and carrying what was actually passed.
            notes = [f"unrecognised --status {raw_status!r} - recorded as failed"]
            status = "failed"
        else:
            notes = []
        metrics, metric_notes = load_metrics(args.metrics)
        notes += metric_notes
        # Keep GitHub's own word for it alongside the mapped status, so `cancelled` stays
        # recoverable downstream even though the ledger's vocabulary has no room for it.
        detail = dict(metrics.get("detail") or {}) if isinstance(metrics.get("detail"), dict) else {}
        if raw_status:
            detail["job_status"] = raw_status
        if detail:
            metrics["detail"] = detail

    record, identity_notes = build_record(args.event, args.pipeline, status, metrics)
    notes += identity_notes
    destination, problems = write_record(record)

    for note in notes + problems:
        # `::warning::` rather than `::error::` and rather than a non-zero exit. A gap in the
        # ledger is a real signal and should be visible in the run summary — but a job whose
        # data load succeeded has succeeded, and failing it over its own bookkeeping would
        # train the maintainer to ignore red. Same posture as the row-count reporting in
        # run_fpl.py, and the same posture sg-janitor.yml takes with its orphan warnings: a
        # warning here means the SLI has a hole, and the run that produced it is named.
        print(f"::warning::ops-ledger ({args.event}, {args.pipeline}): {note}")

    # "-> <destination>" is a claim that the record landed there, so it must not be printed when
    # the write failed — a log line that reads like a success is worse than no log line, and the
    # warning above is easy to scroll past in a long run.
    outcome = f"NOT WRITTEN ({destination})" if problems else f"-> {destination}"
    print(f"ops-ledger {args.event}: {record['run_key']} status={record['status']} {outcome}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

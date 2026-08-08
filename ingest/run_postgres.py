#!/usr/bin/env python3
"""Entrypoint for the Postgres -> Bronze load. Run by `.github/workflows/ingest-bronze.yml`.

    python run_postgres.py               # snapshot app.* + ops.* into Bronze
    python run_postgres.py --dry-run     # write to ./_local_bronze, touch no AWS
    python run_postgres.py --schemas app # narrow the reflection

Destination is chosen by `PITCH_CONTROL_LAKE_BUCKET` exactly as in `run_fpl.py`: set it and
Bronze lands in S3, leave it unset (or pass --dry-run) and it lands on local disk.

**--dry-run is narrower here than it is for FPL.** It removes the AWS *write*, not the source:
this job's source is RDS, so a dry run still opens a real TLS connection to the real database.
There is no offline mode to fall back to, which is the honest position — the thing most worth
proving about this job is that the network path and the credential work.

Connection inputs come from the environment, never from a file (ADR-0019). In CI the workflow
fetches the password from SSM `SecureString` with the ingest role's own OIDC credentials and
puts it here; locally it comes from 1Password via `op read`. Nothing is written to disk in
either case, and `PostgresTarget` keeps the assembled URL out of logs.
"""

from __future__ import annotations

import argparse
import os
import sys
from datetime import datetime, timezone

import dlt

import run_metrics
from postgres.source import DEFAULT_SCHEMAS, PostgresTarget, postgres_source

# Identical layout to the FPL half — see run_fpl.py for why `load_date=` is Hive-style and why
# the prefix stops at the layer (dlt's `dataset_name` supplies the `postgres` segment).
# Final shape: `bronze/postgres/<schema>_<table>/load_date=YYYY-MM-DD/<load_id>.<file_id>.jsonl.gz`.
BRONZE_PREFIX = "bronze"
BRONZE_LAYOUT = "{table_name}/load_date={YYYY}-{MM}-{DD}/{load_id}.{file_id}.{ext}"

# Defaults match infra/variables.tf, so a local run needs only the host, the password and the
# CA bundle. Anything with a default is public information; the two that must be supplied are
# the secret and the path to the cert that proves we are talking to the right server.
ENV_HOST = "PITCH_CONTROL_PG_HOST"
ENV_PORT = "PITCH_CONTROL_PG_PORT"
ENV_DATABASE = "PITCH_CONTROL_PG_DATABASE"
ENV_USER = "PITCH_CONTROL_PG_USER"
ENV_PASSWORD = "PITCH_CONTROL_PG_PASSWORD"
ENV_SSLROOTCERT = "PITCH_CONTROL_PG_SSLROOTCERT"


def build_argparser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Load the OLTP Postgres into Bronze.")
    parser.add_argument(
        "--schemas",
        nargs="+",
        metavar="SCHEMA",
        default=list(DEFAULT_SCHEMAS),
        help=f"Postgres schemas to reflect. Default: {' '.join(DEFAULT_SCHEMAS)}",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Write to ./_local_bronze instead of S3. Still connects to Postgres.",
    )
    return parser


def target_from_env() -> PostgresTarget:
    """Assemble the connection target, failing loudly on anything missing.

    Checked up front, all at once, rather than letting SQLAlchemy fail on the first gap: an
    unattended 06:00 run should say *which* input is missing in its first line of output, not
    surface a `could not translate host name "None"` twenty lines into a stack trace.
    """
    missing = [name for name in (ENV_HOST, ENV_PASSWORD, ENV_SSLROOTCERT) if not os.environ.get(name)]
    if missing:
        raise SystemExit(f"! missing required environment: {', '.join(missing)}")

    sslrootcert = os.environ[ENV_SSLROOTCERT]
    if not os.path.exists(sslrootcert):
        # verify-full without the CA bundle present fails at connect time with a libpq error
        # that reads like a network problem. It is not — it is a missing file, and the
        # workflow curls it because *.pem is gitignored (it cannot be read from the repo).
        raise SystemExit(f"! {ENV_SSLROOTCERT} points at a file that does not exist: {sslrootcert}")

    return PostgresTarget(
        host=os.environ[ENV_HOST],
        port=int(os.environ.get(ENV_PORT) or 5432),
        database=os.environ.get(ENV_DATABASE) or "pitchcontrol",
        username=os.environ.get(ENV_USER) or "pitchadmin",
        password=os.environ[ENV_PASSWORD],
        sslrootcert=sslrootcert,
    )


def main() -> int:
    args = build_argparser().parse_args()

    bucket = os.environ.get("PITCH_CONTROL_LAKE_BUCKET")
    if args.dry_run or not bucket:
        bucket_url = os.path.abspath("_local_bronze")
        destination_label = f"local disk ({bucket_url})"
        if not args.dry_run:
            print("! PITCH_CONTROL_LAKE_BUCKET unset — falling back to a local dry run.")
    else:
        bucket_url = f"s3://{bucket}/{BRONZE_PREFIX}"
        destination_label = bucket_url

    target = target_from_env()

    started = datetime.now(timezone.utc)
    print(f"Postgres -> Bronze  |  {started.isoformat(timespec='seconds')}")
    # `target.url()` renders the password as `***` (SQLAlchemy hides it in __str__), so this
    # is safe to print — and printing the resolved host/db/user is what makes a misconfigured
    # run obvious in the log instead of mysterious.
    print(f"  source:      {target.url()} (sslmode={target.connect_args()['sslmode']})")
    print(f"  destination: {destination_label}")

    engine = target.create_engine()
    source = postgres_source(engine, schemas=args.schemas)

    if not list(source.resources):
        # Nothing to load is a legitimate outcome today: the app layer does not exist yet, so
        # `app` may be empty for weeks. Exiting 0 keeps the scheduled run green — the ADR-0012
        # freshness SLI is what should notice a source that has gone quiet, not a red X here.
        print("\nNo tables found in the selected schemas — nothing to load.")
        # Report zero explicitly rather than returning without writing metrics. The ledger
        # cannot otherwise tell this outcome apart from a run that died before it could report,
        # and those need opposite responses: this one is expected until the app layer exists.
        run_metrics.write({})
        return 0

    destination = dlt.destinations.filesystem(bucket_url=bucket_url, layout=BRONZE_LAYOUT)

    pipeline = dlt.pipeline(
        pipeline_name="postgres_bronze",
        destination=destination,
        # Supplies the `<source>` segment of the Bronze path, exactly as `fpl` does for the
        # other job. Distinct pipeline_name + dataset_name means the two jobs share the lake
        # but never share dlt state.
        dataset_name="postgres",
        progress="log",
    )

    info = pipeline.run(
        source,
        # JSONL, not Parquet — ADR-0003 again. It matters for a different reason on this
        # source than on FPL: JSONB columns have no fixed Parquet schema to write them into,
        # so a strongly-typed Bronze write would have to flatten or stringify them. JSONL
        # keeps the document intact.
        loader_file_format="jsonl",
    )

    elapsed = (datetime.now(timezone.utc) - started).total_seconds()
    print(f"\n{info}")
    print(f"\nOK — {elapsed:.1f}s")

    run_metrics.report(pipeline)

    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Entrypoint for the FPL -> Bronze load. Run by `.github/workflows/ingest-bronze.yml`.

    python run_fpl.py                      # scheduled shape: fetch what can still change
    python run_fpl.py --backfill 1-38      # season history / replay after a schema change
    python run_fpl.py --dry-run            # write to ./_local_bronze, touch no AWS

Destination is chosen by `PITCH_CONTROL_LAKE_BUCKET`: set it and Bronze lands in S3; leave it
unset (or pass --dry-run) and it lands on local disk. That single switch is what lets the
pipeline be validated end-to-end without AWS credentials and without writing to the real lake.

Credentials are never read from a file: in CI, OIDC (ADR-0009/0020) puts short-lived creds in
the environment and boto3/s3fs pick them up; locally the maintainer's IAM profile does the
same. Nothing to put in `.dlt/secrets.toml`, which is why that file is gitignored and absent.
"""

from __future__ import annotations

import argparse
import os
import sys
from datetime import datetime, timezone

import dlt

import run_metrics
from fpl.gameweeks import parse_backfill, select_live_gameweeks
from fpl.source import _get, fpl_source

# Bronze layout (ADR-0003: s3://<bucket>/{bronze,silver,gold}/<source>/...).
#
# The `<source>` directory comes from dlt's `dataset_name`, NOT from this prefix — dlt always
# nests a load under its dataset. Pointing the bucket url at `bronze/fpl` as well would give
# `bronze/fpl/fpl/elements/`, so the prefix stops at the layer and `dataset_name="fpl"`
# supplies the source segment. Final shape: `bronze/fpl/elements/load_date=.../<id>.jsonl.gz`.
#
# `load_date=` is Hive-style on purpose: DuckDB's hive_partitioning (ADR-0004) reads it as a
# real column, so Silver can prune to a date range instead of scanning every load ever made.
# `load_id` is dlt's monotonic run id, so two runs on the same day never collide.
BRONZE_PREFIX = "bronze"
BRONZE_LAYOUT = "{table_name}/load_date={YYYY}-{MM}-{DD}/{load_id}.{file_id}.{ext}"


def build_argparser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Load the FPL API into Bronze.")
    parser.add_argument(
        "--backfill",
        metavar="SPEC",
        help="Explicit gameweeks to load live points for: '5', '1-38', '1,3,5-7'. "
        "Overrides the automatic selection.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Write to ./_local_bronze instead of S3. Makes no AWS calls.",
    )
    return parser


def resolve_gameweeks(backfill: str | None) -> list[int]:
    """Decide which gameweeks to pull live points for, and say why out loud.

    The automatic path costs one extra `bootstrap-static` fetch (the source fetches its own
    copy). That is one request per run against a 1.3 MB cached endpoint — cheap enough that
    threading the payload through would not justify the coupling.
    """
    if backfill:
        gameweeks = parse_backfill(backfill)
        print(f"  backfill override: GW {gameweeks[0]}-{gameweeks[-1]} ({len(gameweeks)} weeks)")
        return gameweeks

    events = _get("bootstrap-static/").get("events") or []
    gameweeks = select_live_gameweeks(events)

    if gameweeks:
        print(f"  gameweeks still in play: {gameweeks}")
    else:
        # Aug 2026 is exactly this case: GW1 is `is_next`, nothing is current or finished.
        print("  no gameweek is current/unsettled — live points skipped (pre-season?)")

    return gameweeks


def main() -> int:
    args = build_argparser().parse_args()

    bucket = os.environ.get("PITCH_CONTROL_LAKE_BUCKET")
    if args.dry_run or not bucket:
        bucket_url = os.path.abspath("_local_bronze")
        target = f"local disk ({bucket_url})"
        if not args.dry_run:
            print("! PITCH_CONTROL_LAKE_BUCKET unset — falling back to a local dry run.")
    else:
        bucket_url = f"s3://{bucket}/{BRONZE_PREFIX}"
        target = bucket_url

    started = datetime.now(timezone.utc)
    print(f"FPL -> Bronze  |  {started.isoformat(timespec='seconds')}")
    print(f"  destination: {target}")

    gameweeks = resolve_gameweeks(args.backfill)

    destination = dlt.destinations.filesystem(
        bucket_url=bucket_url,
        # Hive-partitioned layout, declared here rather than in config.toml so the one thing
        # that determines where Bronze physically lands is visible at the call site.
        layout=BRONZE_LAYOUT,
    )

    pipeline = dlt.pipeline(
        pipeline_name="fpl_bronze",
        destination=destination,
        dataset_name="fpl",
        progress="log",
    )

    info = pipeline.run(
        fpl_source(gameweeks=gameweeks),
        # JSONL, not Parquet: ADR-0003 keeps Bronze in the source's native shape so a load is
        # replayable and schema drift on an unofficial API (ADR-0011) cannot fail a *write*.
        # Parquet's column typing belongs to Silver.
        loader_file_format="jsonl",
    )

    elapsed = (datetime.now(timezone.utc) - started).total_seconds()
    print(f"\n{info}")
    print(f"\nOK — {elapsed:.1f}s")

    # Row counts per table, so a scheduled run's log answers "did it actually load anything?"
    # without opening S3 — and the same numbers persisted for ADR-0025's ledger, which is what
    # turns them into ADR-0012's ingest-freshness SLI instead of a line in a log nobody reads.
    run_metrics.report(pipeline)

    return 0


if __name__ == "__main__":
    sys.exit(main())

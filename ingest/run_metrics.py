"""What a dlt run should say about itself — the metrics half of ADR-0025's ledger.

`ops_ledger.py` knows how to write a run record to the lake; it deliberately knows nothing about
dlt. This module is the other side of that seam: it reads what the pipeline actually did and
leaves it in a file the ledger's `finish` step picks up.

The file is the seam on purpose. The load runs in one step and the ledger writes in another
(`if: always()`, so it still records a run that died), and a step cannot hand a Python object to
the next one. A small JSON file on the runner is the honest way across — and when it is missing,
that absence is itself the signal that the load never got far enough to report.
"""

from __future__ import annotations

import json
import os
import resource
import sys
from pathlib import Path

# Where the workflow expects to find the file. Unset locally, so a laptop run does the work and
# writes nothing — the same "no environment variable, no side effect" switch as the lake bucket.
ENV_METRICS_PATH = "PITCH_CONTROL_RUN_METRICS"


def peak_mem_mb() -> int | None:
    """Peak resident set size for this process, in whole MB.

    `resource.getrusage` rather than psutil, which is also installed: psutil reports memory
    *now*, and the number the ADR-0007 amendment's overflow trip-wire wants is the high-water
    mark — the thing that decides whether a step still fits in a Lambda. getrusage tracks that
    for free, in the stdlib, with no sampling loop to get wrong.

    The unit is the catch: `ru_maxrss` is kilobytes on Linux and *bytes* on macOS/BSD. CI is
    Linux and the maintainer's machine is macOS, so getting this wrong would mean a 1024x
    discrepancy that looks plausible on both.
    """
    try:
        raw = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    except (OSError, ValueError):  # pragma: no cover - getrusage is not expected to fail
        return None
    divisor = 1024 * 1024 if sys.platform == "darwin" else 1024
    return int(raw / divisor)


def table_row_counts(pipeline) -> dict[str, int]:
    """Rows written per table on the last run, dlt's bookkeeping tables excluded.

    Wrapped because the trace is dlt-internal and its shape is not a contract we control. A
    version bump that moves it should cost the run its metrics, not the load it just completed.
    """
    try:
        counts = pipeline.last_trace.last_normalize_info.row_counts
    except AttributeError:
        return {}
    return {table: count for table, count in counts.items() if not table.startswith("_dlt")}


def write(counts: dict[str, int], path: str | None = None) -> str | None:
    """Leave the metrics where the ledger's finish step will look for them.

    Returns the path written, or None when there is nowhere to write — which is the normal
    local case, not a failure.
    """
    destination = path or os.environ.get(ENV_METRICS_PATH)
    if not destination:
        return None

    payload = {
        # The ledger's single headline number. Summed across tables because "how much did this
        # run move" is the question ADR-0012's throughput SLI asks; the per-table breakdown is
        # kept alongside it rather than thrown away, since a run whose total held steady while
        # one table went to zero is the interesting failure and a sum alone hides it.
        "rows_processed": sum(counts.values()),
        "peak_mem_mb": peak_mem_mb(),
        "detail": {"row_counts": dict(sorted(counts.items()))},
    }

    file = Path(destination)
    file.parent.mkdir(parents=True, exist_ok=True)
    file.write_text(json.dumps(payload, indent=2) + "\n")
    return str(file)


def report(pipeline) -> dict[str, int]:
    """Print the per-table counts and persist the metrics. Never fails the caller.

    Both entrypoints end with this. A scheduled run's log should answer "did it actually load
    anything?" without opening S3, and the ledger should get the same numbers rather than a
    second, separately-derived version of them.
    """
    counts = table_row_counts(pipeline)
    for table, count in sorted(counts.items()):
        print(f"  {table:24} {count:>7,} rows")

    try:
        written = write(counts)
    except OSError as exc:
        # Reporting must never be the reason a good load exits non-zero (the ledger takes the
        # same position, for the same reason). The gap shows up as a finish record with null
        # metrics, which is visible and diagnosable; a red run over an unwritable temp file is
        # neither.
        print(f"! could not write run metrics: {exc}")
        return counts

    if written:
        print(f"  metrics -> {written}")
    return counts

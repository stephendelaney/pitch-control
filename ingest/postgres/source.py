"""Postgres (OLTP system of record) -> Bronze, as a dlt source.

Same contract as the FPL half (ADR-0010 EL-only, ADR-0003 Bronze): rows land as the source
returned them, and every interpretation belongs to dbt in Silver (ADR-0005). The differences
are all *upstream* of dlt — reaching RDS at all needs ADR-0021's ephemeral security-group
ingress and ADR-0019's SSM-held password — so this module stays deliberately small.

Two things here are decisions rather than plumbing, and both are load-bearing for Silver:

  1. **Table names are schema-qualified** (`app.raw_landing` -> `app_raw_landing`). dlt's
     namespace is flat, so without this an `app.foo` and an `ops.foo` would collide into one
     table with a merged schema. A single underscore, not `__`: dlt uses `__` for its own
     parent/child table nesting, and `app__raw_landing` would read as a child table of `app`.
  2. **Full snapshot per run, append-only.** No incremental cursor — see `postgres_source`.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Iterable

import dlt
from dlt.sources.sql_database import sql_database
from sqlalchemy import create_engine
from sqlalchemy.engine import Engine
from sqlalchemy.engine.url import URL

# The schemas `infra/sql/0001_init.sql` creates. `app` is the application's own data; `ops` is
# the pipeline bookkeeping ADR-0007/0012 read SLIs from. Both are ingested: `ops.pipeline_runs`
# is what makes run history queryable in Gold alongside the data it describes.
#
# Discovery inside a schema is automatic (every table dlt can reflect), so a table added by an
# app migration is captured from its first run without a code change here. That is the right
# default for Bronze: a table nobody remembered to allowlist has no history to backfill later.
DEFAULT_SCHEMAS: tuple[str, ...] = ("app", "ops")

# TLS is not optional and not configurable. pg16 on RDS ships `rds.force_ssl = 1`, so the
# server would reject a plaintext connection anyway — but `sslmode=require` alone encrypts
# *without* checking who answered. `verify-full` is what makes the public-RDS + IP-locked-SG
# posture honest (CLAUDE.md, infra/README.md -> Connecting): it validates the server cert
# against the RDS CA bundle and checks the hostname.
SSL_MODE = "verify-full"


def bronze_table_name(schema: str, table: str) -> str:
    """`app`, `raw_landing` -> `app_raw_landing`. See decision 1 in the module docstring."""
    return f"{schema}_{table}"


@dataclass(frozen=True)
class PostgresTarget:
    """Everything needed to reach the OLTP instance, as one immutable value.

    A dataclass rather than a DSN string on purpose. The password would otherwise have to be
    percent-encoded into a URL, where a `@` or `/` in a rotated password silently produces a
    connection to the wrong place — and the assembled URL tends to end up in a log line or a
    process listing. SQLAlchemy's `URL.create` escapes the value for us and renders it as
    `***` in `str()`, so there is no correctly-formatted secret lying around to leak.
    """

    host: str
    database: str
    username: str
    password: str
    sslrootcert: str
    port: int = 5432

    def url(self) -> URL:
        return URL.create(
            "postgresql+psycopg2",
            username=self.username,
            password=self.password,
            host=self.host,
            port=self.port,
            database=self.database,
        )

    def connect_args(self) -> dict[str, str]:
        """libpq options passed through psycopg2.

        Kept out of the URL query string: these are connection *policy*, and putting them
        beside the credential is how one of them gets dropped during an edit.
        """
        return {"sslmode": SSL_MODE, "sslrootcert": self.sslrootcert}

    def create_engine(self) -> Engine:
        # `pool_pre_ping` because the ephemeral SG rule and the connection have independent
        # lifetimes: a long extract that outlives its ingress rule fails on a dead socket,
        # and a pre-ping turns that into a clear error rather than a hang.
        return create_engine(
            self.url(),
            connect_args=self.connect_args(),
            pool_pre_ping=True,
        )


def reflect_resources(engine: Engine, schema: str) -> list[Any]:
    """Reflect one Postgres schema into dlt resources, renamed and pinned to append.

    Returns `[]` for a schema with no tables — which is a normal state here, not an error.
    The app layer (ADR-0014/0015) does not exist yet, so `app` is expected to be sparse for
    several weeks; a run that finds nothing is a successful run.
    """
    source = sql_database(
        credentials=engine,
        schema=schema,
        # Views are derived data — a transformation someone wrote in SQL. ADR-0003 keeps
        # Bronze to source-of-record base tables and reserves derivation for Silver, so a
        # view appearing in the OLTP must not quietly become a Bronze table.
        include_views=False,
        # Passed explicitly as None because dlt 1.29.1's own default (`False`) trips dlt's own
        # deprecation warning on every call. Silencing it is not cosmetic: this job runs
        # unattended, and a log that always carries a DeprecationWarning is a log where a real
        # one goes unread. Behaviour is unchanged — `reflection_level` stays the default.
        detect_precision_hints=None,
    )

    resources = []
    for table_name, resource in source.resources.items():
        resource.apply_hints(
            table_name=bronze_table_name(schema, table_name),
            # Bronze is append-only and replayable (ADR-0003). Stated explicitly rather than
            # inherited: a reflected primary key is exactly the hint that would otherwise
            # tempt a future edit into `merge`, which would overwrite history in place.
            write_disposition="append",
        )
        resources.append(resource)

    return resources


@dlt.source(name="postgres", max_table_nesting=0)
def postgres_source(
    engine: Engine,
    schemas: Iterable[str] = DEFAULT_SCHEMAS,
) -> Any:
    """The Postgres Bronze source: every table in `schemas`, snapshotted whole.

    **`max_table_nesting=0` matters more here than it did for FPL.** ADR-0002 makes JSONB the
    landing pattern for semi-structured payloads, so `app.raw_landing.payload` is an arbitrary
    nested document whose shape is *not ours*. Left to normalise, dlt would shred it into
    child tables keyed off whatever that week's payload happened to contain — adding and
    dropping tables as upstream shapes drift, which is the exact failure ADR-0003 keeps out of
    Bronze. At 0, a JSONB column stays one JSON value in one column.

    **No incremental cursor — each run is a full snapshot, appended.** Correct today and
    deliberately so: the tables are tiny, a snapshot needs no per-table knowledge of which
    column is a watermark, and it cannot miss a late-arriving or back-dated row the way a
    high-water mark can. It is also the same shape the FPL job uses for `fixtures`. It does
    not scale — cost is O(rows x runs) — so the trigger to revisit is written down in
    `ingest/README.md`: switch to `dlt.sources.incremental` per table once any table passes
    ~1e5 rows, which is a real-app problem, not a Wk-2 one.
    """
    resources: list[Any] = []
    for schema in schemas:
        found = reflect_resources(engine, schema)
        # `table_name`, not `name`: `apply_hints` renames the destination table while the
        # resource keeps its reflected name, so only the former is what actually lands.
        names = ", ".join(sorted(r.table_name for r in found)) or "(none)"
        print(f"  schema {schema}: {len(found)} table(s) — {names}")
        resources.extend(found)

    return resources

"""Unit tests for the Postgres -> Bronze slice.

No network and no RDS. Reflection is exercised against an **in-memory SQLite** database:
SQLAlchemy reflects it through the same code path Postgres uses, so the parts worth testing —
that tables get schema-qualified names, that every resource is pinned to `append`, and that
the Bronze path comes out in the agreed shape — are all reachable without a database server,
a credential, or an open security group.

What SQLite cannot stand in for is JSONB, and that is exactly the behaviour `max_table_nesting=0`
exists for. So the nesting setting is asserted structurally here, and its *effect* is verified
against the real instance during the load (see ingest/README.md).
"""

from __future__ import annotations

import gzip
import json
from pathlib import Path

import dlt
import pytest
from sqlalchemy import create_engine, text

from postgres.source import (
    DEFAULT_SCHEMAS,
    SSL_MODE,
    PostgresTarget,
    bronze_table_name,
    postgres_source,
    reflect_resources,
)
from run_postgres import BRONZE_LAYOUT, target_from_env

# SQLite's default schema. It is what `sql_database(schema=...)` takes for an in-memory DB,
# and it plays the role `app` / `ops` play against Postgres.
SQLITE_SCHEMA = "main"


@pytest.fixture()
def engine():
    """An in-memory SQLite DB shaped like the seed schema (infra/sql/0001_init.sql)."""
    eng = create_engine("sqlite://")
    with eng.begin() as conn:
        conn.execute(
            text("CREATE TABLE raw_landing (id INTEGER PRIMARY KEY, source TEXT, payload TEXT)")
        )
        conn.execute(
            text("CREATE TABLE pipeline_runs (run_id INTEGER PRIMARY KEY, pipeline TEXT, status TEXT)")
        )
        conn.execute(
            text("INSERT INTO raw_landing (source, payload) VALUES ('fixture', '{\"a\": 1}')")
        )
        conn.execute(text("INSERT INTO pipeline_runs (pipeline, status) VALUES ('t', 'success')"))
    return eng


class TestBronzeTableName:
    def test_qualifies_with_schema(self):
        assert bronze_table_name("app", "raw_landing") == "app_raw_landing"

    def test_same_table_in_two_schemas_does_not_collide(self):
        """The whole reason qualification exists: dlt's table namespace is flat."""
        assert bronze_table_name("app", "runs") != bronze_table_name("ops", "runs")

    def test_avoids_dlt_child_table_separator(self):
        """`__` is dlt's parent/child convention — using it would misrepresent a schema as a parent."""
        assert "__" not in bronze_table_name("app", "raw_landing")


class TestPostgresTarget:
    def target(self, password: str = "s3cr3t", sslrootcert: str = "/tmp/global-bundle.pem"):
        return PostgresTarget(
            host="db.example.com",
            database="pitchcontrol",
            username="pitchadmin",
            password=password,
            sslrootcert=sslrootcert,
        )

    def test_password_is_not_rendered(self):
        """Stringifying the URL must be safe — it is printed in the run log on every run."""
        assert "s3cr3t" not in str(self.target().url())

    def test_url_components(self):
        url = self.target().url()
        assert url.drivername == "postgresql+psycopg2"
        assert (url.host, url.port, url.database, url.username) == (
            "db.example.com",
            5432,
            "pitchcontrol",
            "pitchadmin",
        )
        # Escaping is SQLAlchemy's job, not ours — the point is the value survives intact.
        assert url.password == "s3cr3t"

    def test_password_with_url_metacharacters_survives(self):
        """A rotated password containing `@` or `/` would silently break a hand-built DSN."""
        nasty = "p@ss/w:rd?#&="
        assert self.target(password=nasty).url().password == nasty

    def test_tls_is_verify_full(self):
        """Not `require`: that encrypts without checking who answered (CLAUDE.md, ADR-0021)."""
        assert SSL_MODE == "verify-full"
        args = self.target().connect_args()
        assert args["sslmode"] == "verify-full"
        assert args["sslrootcert"] == "/tmp/global-bundle.pem"

    def test_credentials_stay_out_of_the_query_string(self):
        url = self.target().url()
        assert url.query == {}


class TestTargetFromEnv:
    def env(self, tmp_path: Path) -> dict[str, str]:
        cert = tmp_path / "global-bundle.pem"
        cert.write_text("-----BEGIN CERTIFICATE-----\n")
        return {
            "PITCH_CONTROL_PG_HOST": "db.example.com",
            "PITCH_CONTROL_PG_PASSWORD": "s3cr3t",
            "PITCH_CONTROL_PG_SSLROOTCERT": str(cert),
        }

    def test_defaults_match_terraform(self, tmp_path, monkeypatch):
        for key, value in self.env(tmp_path).items():
            monkeypatch.setenv(key, value)
        target = target_from_env()
        assert (target.port, target.database, target.username) == (5432, "pitchcontrol", "pitchadmin")

    @pytest.mark.parametrize(
        "missing",
        ["PITCH_CONTROL_PG_HOST", "PITCH_CONTROL_PG_PASSWORD", "PITCH_CONTROL_PG_SSLROOTCERT"],
    )
    def test_missing_input_names_itself(self, tmp_path, monkeypatch, missing):
        """An unattended 06:00 failure should say which input is absent, in its first line."""
        for key, value in self.env(tmp_path).items():
            monkeypatch.setenv(key, value)
        monkeypatch.delenv(missing)
        with pytest.raises(SystemExit, match=missing):
            target_from_env()

    def test_absent_ca_bundle_is_caught_before_connecting(self, tmp_path, monkeypatch):
        """`*.pem` is gitignored, so the workflow curls it — a typo there must not read as a
        network error twenty lines into a libpq stack trace."""
        for key, value in self.env(tmp_path).items():
            monkeypatch.setenv(key, value)
        monkeypatch.setenv("PITCH_CONTROL_PG_SSLROOTCERT", str(tmp_path / "nope.pem"))
        with pytest.raises(SystemExit, match="does not exist"):
            target_from_env()


class TestReflection:
    def test_every_table_is_found_and_qualified(self, engine):
        resources = reflect_resources(engine, SQLITE_SCHEMA)
        assert sorted(r.table_name for r in resources) == [
            "main_pipeline_runs",
            "main_raw_landing",
        ]

    def test_every_resource_appends(self, engine):
        """Bronze is append-only (ADR-0003). A reflected primary key must not become a merge."""
        assert all(r.write_disposition == "append" for r in reflect_resources(engine, SQLITE_SCHEMA))

    def test_empty_schema_is_not_an_error(self):
        """`app` is expected to be empty until the app layer lands — that is a successful run."""
        assert reflect_resources(create_engine("sqlite://"), SQLITE_SCHEMA) == []

    def test_source_keeps_nesting_flat(self, engine):
        """The JSONB guard: at any value above 0, dlt shreds `raw_landing.payload` into child
        tables whose existence depends on that week's payload shape (ADR-0002/0003)."""
        source = postgres_source(engine, schemas=[SQLITE_SCHEMA])
        assert source.max_table_nesting == 0

    def test_default_schemas_match_the_seed(self):
        assert DEFAULT_SCHEMAS == ("app", "ops")


class TestBronzeLayout:
    def test_load_lands_in_the_agreed_path(self, engine, tmp_path, monkeypatch):
        """End-to-end against local disk: the contract Silver reads is a *path*, so assert the
        path rather than trusting the layout string. No network, no AWS, no credential."""
        monkeypatch.chdir(tmp_path)
        pipeline = dlt.pipeline(
            pipeline_name="postgres_bronze_test",
            destination=dlt.destinations.filesystem(
                bucket_url=str(tmp_path / "bronze"), layout=BRONZE_LAYOUT
            ),
            dataset_name="postgres",
        )
        pipeline.run(postgres_source(engine, schemas=[SQLITE_SCHEMA]), loader_file_format="jsonl")

        written = sorted(p.relative_to(tmp_path) for p in tmp_path.rglob("*.jsonl.gz"))
        parts = {p.parts[2] for p in written}  # bronze/postgres/<table>/load_date=.../file
        assert parts == {"main_raw_landing", "main_pipeline_runs"}
        assert all(p.parts[3].startswith("load_date=") for p in written)

        landing = next(p for p in written if p.parts[2] == "main_raw_landing")
        row = json.loads(gzip.decompress((tmp_path / landing).read_bytes()).splitlines()[0])
        assert row["source"] == "fixture"
        # dlt's provenance columns are part of the contract documented for Silver.
        assert "_dlt_load_id" in row

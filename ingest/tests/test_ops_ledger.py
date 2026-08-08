"""Unit tests for the pipeline run ledger (ADR-0025).

`ops_ledger.py` lives in `.github/scripts/` because three jobs across two Python environments
share it; it is importable here via `pythonpath` in pytest.ini.

Nothing here touches S3. `write_record` shells out to `aws s3 cp` on the S3 path, so every test
below drives the local-directory path instead — which is the same code up to the final call and
is the path a maintainer actually exercises by hand. The S3 branch is one subprocess invocation,
and its real proof is a workflow run.

The two properties worth defending are both about *pairing*: a start and a finish must agree on
`run_key` (or Silver can never join them), and a run that dies must leave a start with no
finish (or "died silently" becomes indistinguishable from "never ran").
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

import ops_ledger

GITHUB_ENV = {
    "GITHUB_RUN_ID": "31173484914",
    "GITHUB_RUN_ATTEMPT": "1",
    "GITHUB_JOB": "build",
    "GITHUB_WORKFLOW": "transform-build",
    "GITHUB_REPOSITORY": "stephendelaney/pitch-control",
    "GITHUB_SERVER_URL": "https://github.com",
    "GITHUB_SHA": "05db4cf",
}


@pytest.fixture
def ledger_dir(tmp_path, monkeypatch):
    """Point the writer at a temp directory and make sure it cannot reach S3."""
    monkeypatch.delenv("PITCH_CONTROL_LAKE_BUCKET", raising=False)
    monkeypatch.setenv("PITCH_CONTROL_LEDGER_DIR", str(tmp_path))
    for key in GITHUB_ENV:
        monkeypatch.delenv(key, raising=False)
    return tmp_path


def records_in(root: Path) -> list[dict]:
    return [json.loads(path.read_text()) for path in sorted(root.rglob("*.jsonl"))]


class TestRunIdentity:
    def test_run_key_combines_run_attempt_and_job(self, ledger_dir, monkeypatch):
        """All three parts are load-bearing, and each one alone is ambiguous.

        `ingest-bronze` runs two jobs under a single run id, and a re-run reuses that id with a
        new attempt — so a key built from the run id alone would collide across both.
        """
        for key, value in GITHUB_ENV.items():
            monkeypatch.setenv(key, value)
        identity, notes = ops_ledger.run_identity()
        assert identity["run_key"] == "31173484914.1.build"
        assert identity["runtime"] == "github-actions"
        assert identity["run_url"].endswith("/actions/runs/31173484914")
        assert notes == []

    def test_local_run_is_marked_and_warns_that_it_cannot_pair(self, ledger_dir):
        """Off a runner there is no run id, and a laptop build must not look like a scheduled one.

        The SLO is about the unattended schedule, so a manual build counted as a success would
        flatter it. Two invocations must also differ, or a second local run would overwrite the
        first — but that uniqueness is precisely what stops `start` and `finish` pairing, so the
        gap is announced rather than left to be discovered in the mart.
        """
        first, first_notes = ops_ledger.run_identity()
        second, _ = ops_ledger.run_identity()
        assert first["runtime"] == "local"
        assert first["run_key"].startswith("local.")
        assert first["run_key"] != second["run_key"]
        assert any("cannot be paired" in note for note in first_notes)

    def test_an_explicit_run_key_pairs_a_local_run(self, ledger_dir, monkeypatch):
        """The fix for the above, and the reason the override exists.

        Found by rehearsing the local path end to end: `start` and `finish` are two separate
        processes, so nothing in a local environment ties them together on its own. In CI
        GITHUB_RUN_ID does that job, which is why this could only ever break off a runner.
        """
        monkeypatch.setenv(ops_ledger.ENV_RUN_KEY, "local.rehearsal.1")
        first, notes = ops_ledger.run_identity()
        second, _ = ops_ledger.run_identity()
        assert first["run_key"] == second["run_key"] == "local.rehearsal.1"
        assert notes == []

    def test_run_key_is_safe_in_an_object_key(self, ledger_dir, monkeypatch):
        """Job ids come from YAML, so they can carry characters an S3 key should not."""
        monkeypatch.setenv("GITHUB_RUN_ID", "42")
        monkeypatch.setenv("GITHUB_JOB", "dbt build -> Silver + Gold")
        assert ops_ledger.run_identity()[0]["run_key"] == "42.1.dbt-build-Silver-Gold"


class TestPairing:
    def test_start_and_finish_share_a_run_key(self, ledger_dir, monkeypatch):
        """The whole design rests on this: it is the only thing Silver can join on."""
        for key, value in GITHUB_ENV.items():
            monkeypatch.setenv(key, value)

        assert ops_ledger.main(["start", "--pipeline", "transform_dbt"]) == 0
        assert ops_ledger.main(["finish", "--pipeline", "transform_dbt", "--status", "success"]) == 0

        written = {record["event"]: record for record in records_in(ledger_dir)}
        start, finish = written["start"], written["finish"]
        assert start["run_key"] == finish["run_key"] == "31173484914.1.build"
        assert (start["status"], finish["status"]) == ("running", "success")

    def test_a_died_run_leaves_a_start_with_no_finish(self, ledger_dir):
        """Liveness, in the form the object store allows.

        There is no UPDATE in S3, so a stuck `status = 'running'` row is not available to us —
        and is not wanted. An unpaired start says "this run never reported an ending", which is
        the same fact without needing anyone to have written the correction.
        """
        ops_ledger.main(["start", "--pipeline", "fpl_bronze"])

        written = records_in(ledger_dir)
        assert [r["event"] for r in written] == ["start"]
        assert written[0]["status"] == "running"

    def test_the_two_records_land_under_distinct_keys(self, ledger_dir, monkeypatch):
        """Same run_key, different object — otherwise the finish would overwrite the start."""
        for key, value in GITHUB_ENV.items():
            monkeypatch.setenv(key, value)
        ops_ledger.main(["start", "--pipeline", "transform_dbt"])
        ops_ledger.main(["finish", "--pipeline", "transform_dbt", "--status", "success"])
        assert len(list(ledger_dir.rglob("*.jsonl"))) == 2


class TestStatusMapping:
    @pytest.mark.parametrize(
        "job_status,expected",
        [("success", "success"), ("failure", "failed"), ("cancelled", "failed")],
    )
    def test_github_job_status_vocabulary(self, ledger_dir, job_status, expected):
        """The workflows pass GitHub's `job.status` straight through, so all three must map."""
        ops_ledger.main(["finish", "--pipeline", "fpl_bronze", "--status", job_status])
        assert records_in(ledger_dir)[0]["status"] == expected

    def test_cancelled_is_recoverable_from_detail(self, ledger_dir):
        """Folding cancelled into failed loses information, so the original is kept.

        A cancelled run did not produce data, which is what the SLI cares about — but "we
        cancelled it" and "it broke" want different responses from a human reading the mart.
        """
        ops_ledger.main(["finish", "--pipeline", "fpl_bronze", "--status", "cancelled"])
        record = records_in(ledger_dir)[0]
        assert record["status"] == "failed"
        assert record["detail"]["job_status"] == "cancelled"

    def test_an_unknown_status_is_recorded_rather_than_dropped(self, ledger_dir, capsys):
        """A mislabelled run still happened. Losing the record would be the worse error."""
        assert ops_ledger.main(["finish", "--pipeline", "fpl_bronze", "--status", "skipped"]) == 0
        record = records_in(ledger_dir)[0]
        assert record["status"] == "failed"
        assert record["detail"]["job_status"] == "skipped"
        assert "::warning::" in capsys.readouterr().out


class TestMetrics:
    def test_metrics_are_merged_into_the_finish_record(self, ledger_dir, tmp_path):
        metrics = tmp_path / "metrics.json"
        metrics.write_text(
            json.dumps({"rows_processed": 1052, "peak_mem_mb": 212, "detail": {"tables": 9}})
        )
        ops_ledger.main(
            ["finish", "--pipeline", "fpl_bronze", "--status", "success", "--metrics", str(metrics)]
        )
        record = records_in(ledger_dir)[0]
        assert record["rows_processed"] == 1052
        assert record["peak_mem_mb"] == 212
        # The job's own detail survives alongside the status the ledger adds to it.
        assert record["detail"] == {"tables": 9, "job_status": "success"}

    def test_a_missing_metrics_file_still_writes_the_record(self, ledger_dir, capsys):
        """This is the case the finish record exists for.

        A job that died before it could report metrics is precisely when we most need to know
        it ran and failed — so a missing file warns and writes nulls rather than raising.
        """
        exit_code = ops_ledger.main(
            ["finish", "--pipeline", "fpl_bronze", "--status", "failure", "--metrics", "/nope.json"]
        )
        assert exit_code == 0
        record = records_in(ledger_dir)[0]
        assert record["status"] == "failed"
        assert record["rows_processed"] is None
        assert "metrics file not found" in capsys.readouterr().out

    def test_an_unknown_metrics_key_warns_instead_of_populating_nothing(self, ledger_dir, capsys):
        """The writer and the reader are different programs; a typo must not fail silently."""
        path = ledger_dir / "m.json"
        path.write_text(json.dumps({"rows_procesed": 10}))
        ops_ledger.main(
            ["finish", "--pipeline", "fpl_bronze", "--status", "success", "--metrics", str(path)]
        )
        assert "ignored unknown metrics key(s): rows_procesed" in capsys.readouterr().out

    def test_malformed_metrics_do_not_lose_the_record(self, ledger_dir, capsys):
        path = ledger_dir / "m.json"
        path.write_text("{not json")
        assert (
            ops_ledger.main(
                ["finish", "--pipeline", "fpl_bronze", "--status", "success", "--metrics", str(path)]
            )
            == 0
        )
        assert "metrics file unreadable" in capsys.readouterr().out


class TestObjectLayout:
    def test_key_is_hive_partitioned_under_the_ops_runs_source(self, ledger_dir):
        """`load_date=` is what lets DuckDB prune (ADR-0003/0004), same as every Bronze path."""
        ops_ledger.main(["start", "--pipeline", "fpl_bronze"])
        written = next(ledger_dir.rglob("*.jsonl"))
        relative = written.relative_to(ledger_dir).as_posix()
        assert relative.startswith("bronze/ops_runs/load_date=")
        assert relative.endswith(".start.jsonl")

    def test_the_record_is_one_line_of_json(self, ledger_dir):
        """JSONL is a contract, not a file extension — Bronze is read line-delimited."""
        ops_ledger.main(["start", "--pipeline", "fpl_bronze"])
        body = next(ledger_dir.rglob("*.jsonl")).read_text()
        assert body.endswith("\n")
        assert len(body.strip().splitlines()) == 1

    def test_every_seed_schema_column_is_present(self, ledger_dir):
        """The RDS `ops.pipeline_runs` columns all survive the move to the lake (ADR-0025).

        Kept as a test rather than a comment because the point of the ADR is that this ledger
        replaces that table for CI jobs — dropping a column here would quietly narrow what the
        SLIs in ADR-0012 and the trip-wire in the ADR-0007 amendment can ever be built from.
        """
        ops_ledger.main(["finish", "--pipeline", "fpl_bronze", "--status", "success"])
        record = records_in(ledger_dir)[0]
        for column in ("pipeline", "status", "rows_processed", "runtime", "peak_mem_mb", "error"):
            assert column in record, column

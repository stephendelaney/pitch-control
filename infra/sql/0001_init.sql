-- Seed schema for the OLTP system of record (ADR-0002).
--
-- NB: this is NOT applied by Terraform. Terraform provisions the empty RDS instance;
-- schema/migrations are applied by the app layer (ADR-0002 follow-up: "schema lives in
-- infra/ and app/ migrations"). For Wk 1 you can apply it by hand to verify connectivity:
--
--   psql "postgresql://pitchadmin:$TF_VAR_db_password@$(terraform output -raw rds_address):5432/pitchcontrol" \
--        -f sql/0001_init.sql
--
-- It is intentionally minimal: enough to prove the instance is reachable and to stand up
-- the ops bookkeeping that ADR-0007 (orchestration) and ADR-0012 (SLOs) reference.

-- Application data lives under app.* ; operational bookkeeping under ops.*
CREATE SCHEMA IF NOT EXISTS app;
CREATE SCHEMA IF NOT EXISTS ops;

-- Pipeline run ledger. ADR-0007 orchestration writes a row per run; ADR-0012 derives
-- pipeline-success / freshness SLIs from it, and the ADR-0007 amendment derives the
-- "step duration as % of the 15-min Lambda cap" capacity leading indicator from the timings.
CREATE TABLE IF NOT EXISTS ops.pipeline_runs (
    run_id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    pipeline       TEXT        NOT NULL,            -- e.g. 'bronze_fpl', 'silver_dbt'
    status         TEXT        NOT NULL DEFAULT 'running'
                   CHECK (status IN ('running', 'success', 'failed')),
    started_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    finished_at    TIMESTAMPTZ,
    rows_processed BIGINT,
    -- Where the orchestrator ran (lambda | fargate) — feeds the ADR-0007 overflow trip-wire.
    runtime        TEXT,
    peak_mem_mb    INTEGER,
    error          TEXT
);

CREATE INDEX IF NOT EXISTS pipeline_runs_pipeline_started_idx
    ON ops.pipeline_runs (pipeline, started_at DESC);

-- Example of the JSONB landing pattern from ADR-0002 (semi-structured source payloads
-- land here before being modeled). Real source tables come with the dlt work (Wk 2).
CREATE TABLE IF NOT EXISTS app.raw_landing (
    id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    source      TEXT        NOT NULL,
    payload     JSONB       NOT NULL,
    ingested_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

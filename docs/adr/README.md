# Architecture Decision Records

Significant decisions are recorded here using [MADR-lite](template.md). ADRs are immutable once
**Accepted**; we supersede rather than rewrite. New decision? Copy `template.md` to the next number.

## Index & backlog

| ADR | Decision | Status |
|---|---|---|
| [0001](0001-record-architecture-decisions.md) | Record architecture decisions (meta) | ✅ Accepted |
| [0002](0002-postgres-jsonb-system-of-record.md) | PostgreSQL + JSONB for system of record | ✅ Accepted · +amendment 2026-06-30 (Lambda→RDS conn mgmt) |
| [0003](0003-s3-parquet-medallion-lake.md) | S3 + Parquet Medallion lake (Bronze/Silver/Gold) | ✅ Accepted |
| [0004](0004-duckdb-warehouse-engine.md) | DuckDB as warehouse engine (vs Athena / Redshift) | ✅ Accepted |
| [0005](0005-dbt-transformations.md) | dbt for transformations | ✅ Accepted |
| [0006](0006-posthog-cdp.md) | PostHog as product analytics + CDP | ✅ Accepted |
| [0007](0007-github-actions-lambda-orchestration.md) | GitHub Actions + Lambda orchestration (vs Airflow / MWAA) | ✅ Accepted · +amendment 2026-06-30 (Fargate per-step overflow) |
| [0008](0008-metabase-bi.md) | Metabase (local Docker) for BI | ✅ Accepted |
| [0009](0009-terraform-iac.md) | Terraform for IaC | ✅ Accepted |
| [0010](0010-dlt-ingestion.md) | dlt for ingestion | ✅ Accepted |
| [0011](0011-fpl-api-data-source.md) | FPL API as primary data source | ✅ Accepted |
| [0012](0012-slo-error-budget-policy.md) | SLO + error-budget policy | ✅ Accepted |
| [0013](0013-identity-stitching.md) | Identity stitching (user_id ↔ PostHog distinct_id) | ✅ Accepted |
| [0014](0014-react-spa-cloudfront.md) | Web app — React SPA on S3 + CloudFront | ✅ Accepted |
| [0015](0015-api-gateway-lambda-fastapi.md) | API — API Gateway + Lambda (FastAPI) | ✅ Accepted |
| [0016](0016-cognito-auth.md) | Auth & user identity — Amazon Cognito | ✅ Accepted |
| [0017](0017-scoring-source.md) | Scoring source — ingest FPL `event_points` vs compute ourselves | ✅ Accepted |
| [0018](0018-transfer-economy-model.md) | Transfer & economy model — mirror FPL vs simplify | ✅ Accepted |
| [0019](0019-secret-management.md) | Secret management — 1Password (source of truth) + SSM runtime store | ✅ Accepted |
| [0020](0020-iam-authorization-model.md) | IAM authorization model — one role per compute identity, least privilege | ✅ Accepted |

**Status legend:** ✅ Accepted · 📝 Proposed (decision leaning made, rationale not yet written) ·
🔄 Superseded · ⚠️ Deprecated

# The runtime transform identity (ADR-0020) — the role the Wk-3 dbt-duckdb build assumes.
#
# Why this is not just "reuse `pitch-control-ingest`": the two jobs sit on opposite sides of the
# lake's one-way contract. Ingest writes Bronze and must never touch a modelled mart; the dbt
# build reads Bronze and owns Silver and Gold (ADR-0005). Giving ingest write access to Silver
# would let a bad third-party payload (ADR-0011) overwrite a mart directly, and giving dbt write
# access to Bronze would let a modelling bug corrupt the append-only record everything else is
# rebuilt from. One role per compute identity is ADR-0020's rule; this is the case it was
# written for.
#
# Trust is pinned to `main`, same as ingest and `tf-apply`: this role can overwrite the whole
# published Gold layer, so a branch or fork PR must not be able to assume it.
#
# NOTE: because the trust is OIDC-only, this role CANNOT be assumed from a laptop — there is no
# IAM principal in the trust policy. The first proof it works is a real workflow run. That is
# deliberate (adding a human principal to test it would defeat the pinning), but it means the
# policy below is validated by dispatching the workflow, not by `aws sts assume-role`.

data "aws_iam_policy_document" "transform_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repo}:ref:refs/heads/main"]
    }
  }
}

resource "aws_iam_role" "transform" {
  name = "${var.project}-transform"
  # Plain hyphens only - an em dash fails UpdateRoleDescription (see iam_oidc.tf).
  description        = "GitHub Actions OIDC runtime identity for the dbt-duckdb build (main only). Reads bronze/*, writes silver/* and gold/*. (ADR-0020)"
  assume_role_policy = data.aws_iam_policy_document.transform_trust.json
}

data "aws_iam_policy_document" "transform_lake" {
  statement {
    sid    = "ListLakeBucket"
    effect = "Allow"
    # Unconditioned for the same reason as ingest: DuckDB's httpfs resolves globs by listing,
    # and an `s3:prefix` condition turns that into errors that surface far from their cause.
    # Listing exposes key names only, not object contents.
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [aws_s3_bucket.lake.arn]
  }

  statement {
    sid    = "ReadBronze"
    effect = "Allow"
    # Read-only, and this is the load-bearing half of the split. Bronze is the append-only
    # record (ADR-0003); Silver is derived from it and can always be rebuilt, so the transform
    # job never needs to write here. ADR-0023 reads the `_dlt_loads` ledger from this prefix to
    # pick the snapshot, which is also a read.
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.lake.arn}/bronze/*"]
  }

  # The one exception to "this role never writes Bronze" (ADR-0025). The transform job records
  # its own run in the lake ledger, and that ledger lives under bronze/ because it is a source
  # in its own right rather than something derived from one.
  #
  # It is a deliberately narrow exception and the narrowness is the whole argument: PutObject on
  # a single prefix, no GetObject (this role writes records, it never reads the ledger back — a
  # future SLI model reads it as Bronze like any other source), and no reach into bronze/fpl/ or
  # bronze/postgres/. The alternative considered and rejected was writing the row to RDS
  # `ops.pipeline_runs`, which would have required giving this identity the database secret and
  # `ec2:AuthorizeSecurityGroupIngress` — the account's most sensitive grant — to log that a
  # build ran. Widening a data-plane role to publish telemetry is the wrong direction.
  statement {
    sid       = "AppendRunLedger"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.lake.arn}/bronze/ops_runs/*"]
  }

  statement {
    sid    = "WriteSilverAndGold"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      # DuckDB's S3 writer uses multipart upload. Create/Upload/Complete all authorize as
      # s3:PutObject; only the abort path needs its own action, and without it a failed write
      # leaves billable orphaned parts that no one can clean up.
      "s3:AbortMultipartUpload",
    ]
    resources = [
      "${aws_s3_bucket.lake.arn}/silver/*",
      "${aws_s3_bucket.lake.arn}/gold/*",
    ]
  }

  # Deliberately NO s3:DeleteObject. dbt-duckdb's external materialization overwrites each
  # model's Parquet file in place with a PUT, so deletion is not on the write path — and
  # withholding it means a modelling bug cannot silently remove a mart, only replace it with
  # something wrong (which the 148 tests are there to catch, and which object versioning on the
  # lake makes recoverable). If a future materialization genuinely needs to prune stale
  # partitions, add it then, with a comment saying which model forced it.
}

resource "aws_iam_role_policy" "transform_lake" {
  name   = "${var.project}-transform-lake"
  role   = aws_iam_role.transform.id
  policy = data.aws_iam_policy_document.transform_lake.json
}

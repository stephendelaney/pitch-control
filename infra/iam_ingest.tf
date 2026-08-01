# The runtime ingest identity (ADR-0020) — the role the Wk-2 dlt Bronze jobs assume.
#
# This resolves the follow-up `iam_oidc.tf` flagged when it parked lake-RW on `tf-apply`:
# "do not let dlt and `terraform apply` share a role long-term." They are different trust
# boundaries. `tf-apply` is *infrastructure* authority — it can create and destroy the
# account. An ingest job is *data-plane* authority that runs unattended on a schedule against
# an unofficial third-party API (ADR-0011); it should be able to write Bronze and nothing else.
# Sharing one role means a bug or a compromised dependency in a data job inherits the ability
# to reshape the account.
#
# Trust is pinned to `main` for the same reason `tf-apply` is (ADR-0020's named footgun): this
# role can write to the lake, so a branch or fork PR must not be able to assume it.

data "aws_iam_policy_document" "ingest_trust" {
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

resource "aws_iam_role" "ingest" {
  name               = "${var.project}-ingest"
  description        = "GitHub Actions OIDC runtime identity for the dlt Bronze jobs (main only). Writes bronze/* only. (ADR-0020/0021)"
  assume_role_policy = data.aws_iam_policy_document.ingest_trust.json
}

# Bronze-only write. Scoped to the `bronze/` prefix, so this identity cannot touch Silver or
# Gold — dbt owns those (ADR-0005), and a runaway ingest job must not be able to overwrite
# modelled marts.
data "aws_iam_policy_document" "ingest_bronze_rw" {
  statement {
    sid    = "ListLakeBucket"
    effect = "Allow"
    # Listing is deliberately NOT prefix-conditioned. s3fs (under dlt's filesystem
    # destination) probes the bucket root to resolve paths, and an `s3:prefix` condition
    # makes those probes fail in ways that surface as confusing dlt errors. Listing exposes
    # key names only — no object contents — so the trade buys reliability cheaply.
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [aws_s3_bucket.lake.arn]
  }

  statement {
    sid    = "WriteBronzeObjects"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      # dlt cleans up its own temp/partial load artifacts, and its filesystem destination
      # keeps pipeline state under the same prefix. Bronze data itself stays append-only by
      # convention (ADR-0003) — this grant is what the loader needs, not a licence to prune.
      "s3:DeleteObject",
    ]
    resources = ["${aws_s3_bucket.lake.arn}/bronze/*"]
  }
}

resource "aws_iam_role_policy" "ingest_bronze_rw" {
  name   = "${var.project}-ingest-bronze-rw"
  role   = aws_iam_role.ingest.id
  policy = data.aws_iam_policy_document.ingest_bronze_rw.json
}

# NOT granted here, deliberately — these arrive with the Postgres->S3 slice, which is the
# first thing that needs them (ADR-0021 puts both on THIS role, never on `tf-apply`):
#
#   * ec2:AuthorizeSecurityGroupIngress / RevokeSecurityGroupIngress / DescribeSecurityGroup*,
#     resource-scoped to the RDS SG — the ephemeral runner-IP ingress dance.
#   * ssm:GetParameter + kms:Decrypt on the RDS password parameter (ADR-0019).
#
# The FPL job needs neither: FPL is a public endpoint reached by plain outbound HTTPS, with no
# secret to fetch. Granting them now would be permission without a consumer.

# GitHub Actions OIDC -> AWS IAM role (ADR-0009). Keyless deploys: NO long-lived AWS
# access keys exist. ADR-0007's orchestration assumes this role.

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  # GitHub's OIDC CA thumbprints. AWS now validates against its trusted CA store, but the
  # resource still requires the list; these are the documented values.
  thumbprint_list = [
    "6938fd4d98bab03faadb97b34396831e3780aea1",
    "1c58a3a8518e8759bf075b76b750d4f2df264fcb",
  ]
}

# Trust policy: only this repo's workflows may assume the role. The sub claim is pinned to
# the repo (any branch/PR for now); tighten to specific refs/environments when CI matures.
data "aws_iam_policy_document" "gha_trust" {
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
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repo}:*"]
    }
  }
}

resource "aws_iam_role" "gha_deploy" {
  name               = "${var.project}-gha-deploy"
  description        = "Assumed by GitHub Actions via OIDC. Keyless. (ADR-0007/0009)"
  assume_role_policy = data.aws_iam_policy_document.gha_trust.json
}

# Starter permissions: read/write the medallion lake. This is the FIRST real use of the
# role — the Wk 2 dlt jobs land Bronze in S3 from Actions. Terraform-deploy permissions
# (the broader infra-management policy CI needs to run apply) are added in Wk 5 when CI
# deploys land; kept out now to stay least-privilege.
data "aws_iam_policy_document" "gha_lake_rw" {
  statement {
    sid       = "ListLakeBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [aws_s3_bucket.lake.arn]
  }

  statement {
    sid       = "ReadWriteLakeObjects"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.lake.arn}/*"]
  }
}

resource "aws_iam_role_policy" "gha_lake_rw" {
  name   = "${var.project}-lake-rw"
  role   = aws_iam_role.gha_deploy.id
  policy = data.aws_iam_policy_document.gha_lake_rw.json
}

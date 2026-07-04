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

# ADR-0020: one role per compute identity, scoped to its trust boundary. The single CI
# deploy role is split by *privilege level* into two OIDC-assumed roles:
#
#   tf-plan  — READ-ONLY, trust = any branch/PR (repo:<owner>/<repo>:*). Used by
#              `terraform plan` on PRs. Read-only so untrusted PR code (forks, a compromised
#              action) cannot mutate anything.
#   tf-apply — WRITE, trust = pinned to refs/heads/main (StringEquals, not a StringLike
#              wildcard — ADR-0020's named footgun). Used by `terraform apply` on main; the
#              account's real mutation authority.
#
# IAM-write stays OUT of tf-apply (ADR-0020): CI can never grant itself IAM; the OIDC
# provider + these roles are bootstrapped out-of-band. The broader Terraform-deploy policy
# CI needs to run `apply` lands in Wk 5.

# --- tf-plan: read-only, any ref ---
data "aws_iam_policy_document" "tf_plan_trust" {
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

    # Any branch or PR of this repo — safe because the role is read-only.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repo}:*"]
    }
  }
}

resource "aws_iam_role" "tf_plan" {
  name               = "${var.project}-tf-plan"
  description        = "GitHub Actions OIDC, READ-ONLY (any ref). `terraform plan` on PRs. (ADR-0020)"
  assume_role_policy = data.aws_iam_policy_document.tf_plan_trust.json
}

# --- tf-apply: write, pinned to main ---
data "aws_iam_policy_document" "tf_apply_trust" {
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

    # Pinned to the default branch — StringEquals on the exact ref, NOT a StringLike
    # wildcard. This is the mutation authority; a loose match here reopens the account
    # (ADR-0020 review-checklist item).
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repo}:ref:refs/heads/main"]
    }
  }
}

resource "aws_iam_role" "tf_apply" {
  name               = "${var.project}-tf-apply"
  description        = "GitHub Actions OIDC, WRITE (main only). `terraform apply` + Wk-2 lake write. (ADR-0020)"
  assume_role_policy = data.aws_iam_policy_document.tf_apply_trust.json
}

# Starter permissions: read/write the medallion lake — the FIRST real use of a CI role, the
# Wk 2 dlt jobs landing Bronze in S3 from Actions (runs on main). Attached to tf-apply, the
# main-pinned write identity. NOTE: when the dedicated shared runtime exec role lands
# (ADR-0019/0020 Wk-2 follow-up), this data-plane write MIGRATES there so tf-apply holds only
# infra-management authority — do not let dlt and `terraform apply` share a role long-term.
data "aws_iam_policy_document" "lake_rw" {
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

resource "aws_iam_role_policy" "lake_rw" {
  name   = "${var.project}-lake-rw"
  role   = aws_iam_role.tf_apply.id
  policy = data.aws_iam_policy_document.lake_rw.json
}

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
  description        = "GitHub Actions OIDC, WRITE (main only). `terraform apply` — infra management only. (ADR-0020)"
  assume_role_policy = data.aws_iam_policy_document.tf_apply_trust.json
}

# Lake object access for tf-apply, narrowed to what Terraform itself manages.
#
# This used to be blanket read/write over the whole lake, parked here as "starter permissions"
# because the Wk-2 dlt jobs had nowhere else to live. That follow-up is now done: dlt assumes
# the dedicated runtime role in `iam_ingest.tf`, which holds bronze/* and nothing more. What
# remains for tf-apply is the only lake object Terraform is the author of — the zero-byte
# `.keep` markers in `s3.tf` that document the medallion layout.
#
# So tf-apply keeps infra-management authority and loses data-plane authority: it can no
# longer read a Bronze payload or overwrite a Gold mart, neither of which `terraform apply`
# has any business doing.
data "aws_iam_policy_document" "lake_markers" {
  statement {
    sid       = "ListLakeBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [aws_s3_bucket.lake.arn]
  }

  statement {
    sid       = "ManageLayerMarkers"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = [for layer in local.medallion_layers : "${aws_s3_bucket.lake.arn}/${layer}/.keep"]
  }
}

resource "aws_iam_role_policy" "lake_markers" {
  name   = "${var.project}-lake-markers"
  role   = aws_iam_role.tf_apply.id
  policy = data.aws_iam_policy_document.lake_markers.json
}

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

# --- Postgres -> Bronze additions (the second Wk-2 slice) ---------------------------------
#
# Everything below exists for the Postgres job only. The FPL job needs none of it: FPL is a
# public endpoint reached by plain outbound HTTPS, with no secret to fetch and no network
# permission to arrange. Both grants land HERE and never on `tf-apply` — that is the explicit
# instruction in ADR-0021, and the whole point of this file's existence.

# ADR-0021's ephemeral ingress: the runner authorizes its own /32 on 5432, runs dlt, and
# revokes. That is a data job mutating security config, which is ugly enough that the policy
# is written to make the blast radius obvious: it can open and close rules on exactly ONE
# security group, and can do nothing else to the network.
data "aws_iam_policy_document" "ingest_sg_ephemeral" {
  statement {
    sid    = "DescribeSecurityGroupsAndRules"
    effect = "Allow"
    # `ec2:Describe*` cannot be resource-scoped — the API rejects a policy that tries. This is
    # an AWS limitation, not a shortcut: read-only visibility of SG metadata across the
    # account is the floor. The workflow resolves the RDS SG by its `Name` tag rather than a
    # hardcoded id, because `network.tf` uses `name_prefix` + `create_before_destroy` — the id
    # changes if the SG is ever replaced, and a stale hardcoded id would fail closed but noisily.
    actions = [
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeSecurityGroupRules",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "ManageEphemeralIngressOnRdsSgOnly"
    effect = "Allow"
    actions = [
      "ec2:AuthorizeSecurityGroupIngress",
      "ec2:RevokeSecurityGroupIngress",
    ]
    # The one SG this project has. Constructed rather than read from a data source so the
    # scope is legible at a glance: this role cannot touch any other security group.
    resources = [
      "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:security-group/${aws_security_group.rds.id}",
    ]
  }

  statement {
    sid    = "StampEphemeralRulesAtCreation"
    effect = "Allow"
    # The runbook (runbooks/orphaned-sg-rule.md) detects orphans by the ManagedBy/RunId/
    # CreatedAt tags the workflow puts on each rule, so tagging is not cosmetic — it is the
    # cleanup mechanism. Rule ids are only known after the call, hence a wildcard resource;
    # the CreateAction condition is what stops this from being a general tagging grant.
    actions   = ["ec2:CreateTags"]
    resources = ["arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:security-group-rule/*"]

    condition {
      test     = "StringEquals"
      variable = "ec2:CreateAction"
      values   = ["AuthorizeSecurityGroupIngress"]
    }
  }
}

resource "aws_iam_role_policy" "ingest_sg_ephemeral" {
  name   = "${var.project}-ingest-sg-ephemeral"
  role   = aws_iam_role.ingest.id
  policy = data.aws_iam_policy_document.ingest_sg_ephemeral.json
}

# Endpoint discovery. The workflow could hold the hostname in a repo variable instead, but the
# endpoint changes on every destroy/recreate — and the cost posture in infra/README.md makes
# teardown a routine lever, not a rare event. Reading it from the (stable) instance identifier
# at run time means a rebuilt database does not silently point ingest at a dead host.
#
# Read-only, and scoped to this one instance. Describe on RDS returns no credential material.
data "aws_iam_policy_document" "ingest_rds_describe" {
  statement {
    sid       = "DiscoverRdsEndpoint"
    effect    = "Allow"
    actions   = ["rds:DescribeDBInstances"]
    resources = [aws_db_instance.postgres.arn]
  }
}

resource "aws_iam_role_policy" "ingest_rds_describe" {
  name   = "${var.project}-ingest-rds-describe"
  role   = aws_iam_role.ingest.id
  policy = data.aws_iam_policy_document.ingest_rds_describe.json
}

# ADR-0019's runtime secret path: 1Password is the source of truth, SSM SecureString is the
# machine-readable copy, and the role reads it with no stored credential of its own.
#
# The parameter itself is deliberately NOT a Terraform resource. ADR-0019 prescribes seeding
# it with `op read … | aws ssm put-parameter` (infra/README.md -> "Seeding the runtime DB
# secret"), which keeps two properties worth more than the convenience of managing it here:
# `tf-apply` never gains SSM *write* authority, and the secret's lifecycle is decoupled from
# the infra apply. An IAM policy may name a parameter that does not exist yet, so this grant
# is valid before the seed and starts working the moment the seed lands.
data "aws_iam_policy_document" "ingest_rds_secret" {
  statement {
    sid       = "ReadRdsPasswordParameter"
    effect    = "Allow"
    actions   = ["ssm:GetParameter"]
    resources = ["arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter${local.rds_password_ssm_parameter}"]
  }

  statement {
    sid    = "DecryptSecureStringViaSsm"
    effect = "Allow"
    # SecureString uses the AWS-managed `alias/aws/ssm` key (ADR-0019 — a customer-managed key
    # is a paid escalation we have not taken). Resolving that key's ARN with a data source
    # would look tighter but would be worse: the AWS-managed key is created lazily on the
    # account's first SecureString, so the lookup fails at PLAN time until the seed has run —
    # a chicken-and-egg that breaks CI for reasons unrelated to the change being planned.
    # The ViaService condition buys back the scope: decrypt is only usable through SSM, and
    # the GetParameter statement above already limits that to one parameter.
    actions   = ["kms:Decrypt"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${var.aws_region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "ingest_rds_secret" {
  name   = "${var.project}-ingest-rds-secret"
  role   = aws_iam_role.ingest.id
  policy = data.aws_iam_policy_document.ingest_rds_secret.json
}

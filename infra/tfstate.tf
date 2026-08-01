# B6 — remote Terraform state (ADR-0009).
#
# Wk 1 shipped with LOCAL state as a deliberate, temporary deviation: 20 live AWS resources
# tracked only in one file on one laptop. Losing it doesn't lose the resources — it loses the
# *map* to them (every resource then has to be imported by hand, or orphaned and paid for).
# The deferral's precondition ("after the first successful apply") is met, so state moves to S3.
#
# CHICKEN-AND-EGG: this bucket is created by the same config whose state it will hold. That is
# resolved by ordering, not by a second config — see infra/README.md → "Remote state (B6)":
#   1. apply with the LOCAL backend still active  → creates the bucket
#   2. flip backend.tf to `backend "s3"`          → `terraform init -migrate-state`
# After step 2 the bucket is described by the state it stores. That self-reference is fine in
# steady state and has exactly one sharp edge: teardown. See the prevent_destroy note below.

locals {
  tfstate_bucket_name = "${var.project}-tfstate-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket" "tfstate" {
  bucket = local.tfstate_bucket_name

  # The state file IS the map to every live resource in the account, and this bucket is
  # self-referential (see header) — a destroy would delete the backend mid-operation. Refuse
  # at plan time. NB: this makes a bare `terraform destroy` FAIL, which is intentional; the
  # teardown lever documented in STATUS/README now has an explicit sequence to follow.
  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Name = local.tfstate_bucket_name
    Role = "terraform-state"
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Terraform state holds var.db_password IN PLAINTEXT (`sensitive` redacts CLI output, not the
# state file). SSE-S3 is the $0 option; it protects at rest but any principal with s3:GetObject
# on this bucket can read the RDS master password — which is why the IAM grants below are
# object-scoped to exactly one key and nothing else. (SSE-KMS with a CMK would add per-key
# charges — a paid escalation, out of scope under the cost posture.)
resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

# Versioning is NOT optional here (unlike the lake, where it's a nice-to-have): it is the only
# recovery path from a corrupted or truncated state write. Every apply overwrites the same key.
resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  depends_on = [aws_s3_bucket_versioning.tfstate]

  rule {
    id     = "abort-incomplete-multipart"
    status = "Enabled"
    filter {}
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  # Kept far longer than the lake's 30 days: old state versions are the rollback path, and a
  # bad apply can go unnoticed for weeks. State objects are tiny (KBs), so this costs nothing.
  rule {
    id     = "expire-noncurrent-versions"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days = 365
    }
  }
}

# Same TLS-only posture as the lake (B4) and RDS (`rds.force_ssl = 1`). Deny-only, so it grants
# nothing and is not a "public" policy — it coexists with block_public_policy = true.
data "aws_iam_policy_document" "tfstate_bucket" {
  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions   = ["s3:*"]
    resources = [aws_s3_bucket.tfstate.arn, "${aws_s3_bucket.tfstate.arn}/*"]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  policy = data.aws_iam_policy_document.tfstate_bucket.json

  depends_on = [aws_s3_bucket_public_access_block.tfstate]
}

# --- CI access to remote state (ADR-0020 role split) ---
#
# Without these, the OIDC roles can't use the backend at all: the moment CI stops passing
# `-backend=false`, `terraform init` fails on AccessDenied. Granted now so the Wk-5 CI-apply
# work doesn't rediscover it.
#
# The asymmetry below is the whole point of the split, and it's subtler than "plan reads,
# apply writes": `terraform plan` also ACQUIRES A LOCK, so the read-only role needs write
# access — but only to the lock object (<key>.tflock), never to the state object itself.

locals {
  tfstate_key      = "infra/terraform.tfstate"
  tfstate_obj_arn  = "${aws_s3_bucket.tfstate.arn}/${local.tfstate_key}"
  tfstate_lock_arn = "${aws_s3_bucket.tfstate.arn}/${local.tfstate_key}.tflock"
}

data "aws_iam_policy_document" "tfstate_ro" {
  statement {
    sid       = "ListStateBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [aws_s3_bucket.tfstate.arn]
  }

  statement {
    sid       = "ReadState"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = [local.tfstate_obj_arn]
  }

  # Lock only. A read-only plan must still take (and release) the lock, so this is the one
  # mutation tf-plan is allowed — scoped to the .tflock key so it can never write state.
  statement {
    sid       = "ManageStateLock"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = [local.tfstate_lock_arn]
  }
}

resource "aws_iam_role_policy" "tf_plan_state_ro" {
  name   = "${var.project}-tfstate-ro"
  role   = aws_iam_role.tf_plan.id
  policy = data.aws_iam_policy_document.tfstate_ro.json
}

data "aws_iam_policy_document" "tfstate_rw" {
  statement {
    sid       = "ListStateBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [aws_s3_bucket.tfstate.arn]
  }

  statement {
    sid       = "ReadWriteStateAndLock"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = [local.tfstate_obj_arn, local.tfstate_lock_arn]
  }
}

resource "aws_iam_role_policy" "tf_apply_state_rw" {
  name   = "${var.project}-tfstate-rw"
  role   = aws_iam_role.tf_apply.id
  policy = data.aws_iam_policy_document.tfstate_rw.json
}

# RDS Postgres — the OLTP system of record (ADR-0002). Free-tier sized: db.t4g.micro,
# 20 GB gp3, single-AZ. The ADR-0002 amendment (Lambda->RDS connection management) governs
# how *callers* connect (reserved concurrency + handler-scoped pooling); it does not change
# this instance. There are no Lambdas in Wk 1, so those caps land when the API/dlt arrive.

resource "aws_db_subnet_group" "main" {
  name       = "${var.project}-db-subnets"
  subnet_ids = data.aws_subnets.default.ids

  tags = {
    Name = "${var.project}-db-subnets"
  }
}

resource "aws_db_instance" "postgres" {
  identifier = "${var.project}-pg"

  engine         = "postgres"
  engine_version = var.pg_version
  instance_class = "db.t4g.micro" # free-tier eligible

  allocated_storage = 20    # free-tier: up to 20 GB
  storage_type      = "gp2" # AWS documents the RDS free tier as 20 GB of gp2; gp3 coverage is
  # ambiguous, so we match the documented type to keep the $0 guarantee airtight (gp2 supports
  # encryption, backups, etc. identically). Revisit gp3 if we ever outgrow free-tier storage.
  storage_encrypted = true # KMS default key — no extra cost

  db_name  = var.db_name
  username = var.db_username
  password = var.db_password
  port     = 5432

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = true

  multi_az = false
  # The AWS Free *plan* (post-2025-07 restricted account) caps backup retention below 7 days and
  # rejects a longer period at CreateDBInstance (FreeTierRestrictionError, 2026-07-14). 1 day keeps
  # automated backups + PITR on while staying inside the free-plan limit; raise it after the
  # month-6 exit off the free plan. (0 would disable automated backups entirely — avoid.)
  backup_retention_period    = 1
  auto_minor_version_upgrade = true
  apply_immediately          = true # dev: take changes now, not in the maintenance window

  # Dev posture: easy teardown. Flip these for anything resembling prod.
  deletion_protection = false
  skip_final_snapshot = true

  # performance_insights_enabled stays off — PI's free retention is limited and we keep $0.

  tags = {
    Name = "${var.project}-pg"
  }
}

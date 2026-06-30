# Wk 1 networking: use the account's DEFAULT VPC + its public subnets (ADR decision —
# "default VPC, publicly accessible + IP-locked SG"). Simplest path to a reachable RDS
# for local dev/dbt. A dedicated private-subnet VPC is a deliberate later upgrade.

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# Security group for RDS: ingress on 5432 only from the IP-locked CIDRs (var.allowed_cidrs).
resource "aws_security_group" "rds" {
  name_prefix = "${var.project}-rds-"
  description = "Postgres 5432 ingress, IP-locked. Managed by Terraform."
  vpc_id      = data.aws_vpc.default.id

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name = "${var.project}-rds"
  }
}

resource "aws_vpc_security_group_ingress_rule" "postgres" {
  for_each = toset(var.allowed_cidrs)

  security_group_id = aws_security_group.rds.id
  description       = "Postgres from allowed CIDR"
  cidr_ipv4         = each.value
  from_port         = 5432
  to_port           = 5432
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.rds.id
  description       = "Allow all egress"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

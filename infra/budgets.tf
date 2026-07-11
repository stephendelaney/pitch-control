# B2 — cost guard. A monthly COST budget with a $1 limit that emails on actual OR forecast
# spend crossing it. The first two budgets per account are free, so this is $0.
#
# Why $1 with default cost types (credits INCLUDED): this account is on the post-July-2025
# credits plan (A2), so measured net cost stays ~$0 while credits cover the ~$12–14/mo RDS
# drawdown. Counting credits means the alarm stays quiet under the plan and fires the moment
# real, out-of-pocket money starts — i.e. it doubles as the credit-exhaustion / month-6 exit
# tripwire. (To watch gross drawdown instead, set cost_types.include_credit = false.)
resource "aws_budgets_budget" "monthly_cost" {
  name         = "${var.project}-monthly-cost"
  budget_type  = "COST"
  limit_amount = "1"
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # Credits/refunds counted (AWS defaults). Stated explicitly because it's the crux of the
  # "$1 = alert when I start paying real money" design above.
  cost_types {
    include_credit = true
    include_refund = true
  }

  # Actual spend over $1.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.budget_notification_email]
  }

  # Forecast to exceed $1 this month — earlier warning than waiting for actuals.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.budget_notification_email]
  }
}

# B9 — gross-drawdown watch. The monthly_cost budget above counts credits, so it stays
# silent until out-of-pocket money starts (by design) — which means it gives ZERO visibility
# into how fast the ~$100–200 of plan credits are burning. A runaway resource could drain the
# credits in weeks and the first signal would be the $1 tripwire *after* the money is gone.
#
# This second budget excludes credits (include_credit = false) so it measures GROSS spend, and
# sets the limit just above the expected steady-state burn (~$13/mo RDS + noise). Quiet in a
# normal month; fires when drawdown exceeds plan — i.e. it catches a cost anomaly *while credits
# still mask it* from monthly_cost. The first two budgets per account are free, so this is $0.
resource "aws_budgets_budget" "monthly_gross" {
  name         = "${var.project}-monthly-gross"
  budget_type  = "COST"
  limit_amount = "15"
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # Credits EXCLUDED — this is the whole point: measure real drawdown, not net-of-credits cost.
  cost_types {
    include_credit = false
    include_refund = true
  }

  # Actual gross spend over the ~steady-state limit.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.budget_notification_email]
  }

  # Forecast to exceed the limit this month — catches an accelerating burn early.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.budget_notification_email]
  }
}

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

# Optional cost guard (budgets + alert rules are free). Created only when an email is set.
locals {
  budget_email  = trimspace(var.budget_alert_email != "" ? var.budget_alert_email : local.budget.alert_email)
  create_budget = local.budget_email != ""
}

resource "oci_budget_budget" "guard" {
  count = local.create_budget ? 1 : 0

  compartment_id = local.tenancy_ocid
  display_name   = "${local.name_prefix}-free-tier-guard"
  description    = "Alerts on any spend - this stack should cost nothing."
  amount         = local.budget.monthly_amount
  reset_period   = "MONTHLY"
  target_type    = "COMPARTMENT"
  targets        = [local.tenancy_ocid] # whole tenancy: any charge anywhere is a red flag
  freeform_tags  = local.freeform_tags
}

resource "oci_budget_alert_rule" "any_spend" {
  count = local.create_budget ? 1 : 0

  budget_id      = oci_budget_budget.guard[0].id
  display_name   = "any-actual-spend"
  type           = "ACTUAL"
  threshold_type = "ABSOLUTE"
  threshold      = local.budget.alert_threshold
  recipients     = local.budget_email
  message        = "OCI tenancy has incurred charges. Check Cost Analysis - the free VPS stack should be $0."
}

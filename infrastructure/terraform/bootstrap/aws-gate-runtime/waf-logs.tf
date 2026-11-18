# WAF logging to CloudWatch Logs needs a log delivery (resource *) and a log
# resource policy for delivery.logs.amazonaws.com. Neither can carry a stack
# tag, so the shared-account ownership deny refuses them. The service role may
# manage log deliveries (DenyNonGateChanges exempts *LogDelivery); the account
# resource policy stays denied and is owned here, limited to gate WAF log groups.
resource "aws_cloudwatch_log_resource_policy" "gate_waf_logs" {
  count       = var.shared_account ? 1 : 0
  policy_name = "honua-gate-waf-logs"
  policy_document = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "GateWafLogDelivery"
      Effect    = "Allow"
      Principal = { Service = "delivery.logs.amazonaws.com" }
      Action    = ["logs:CreateLogStream", "logs:PutLogEvents"]
      Resource  = "arn:aws:logs:us-east-1:${var.member_account_id}:log-group:aws-waf-logs-honua-gate-*:log-stream:*"
      Condition = {
        StringEquals = { "aws:SourceAccount" = var.member_account_id }
        ArnLike      = { "aws:SourceArn" = "arn:aws:logs:us-east-1:${var.member_account_id}:*" }
      }
    }]
  })
}

# CloudFront access logs (standard logging v2) go to /aws/vendedlogs/honua/<stack>/edge-access. CreateDelivery needs
# the same delivery.logs.amazonaws.com write grant, which the stack cannot add (the account resource policy stays
# denied), so it is owned here, limited to gate stacks' vended-log groups.
resource "aws_cloudwatch_log_resource_policy" "gate_edge_access_logs" {
  count       = var.shared_account ? 1 : 0
  policy_name = "honua-gate-edge-access-logs"
  policy_document = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "GateEdgeAccessLogDelivery"
      Effect    = "Allow"
      Principal = { Service = "delivery.logs.amazonaws.com" }
      Action    = ["logs:CreateLogStream", "logs:PutLogEvents"]
      Resource  = "arn:aws:logs:us-east-1:${var.member_account_id}:log-group:/aws/vendedlogs/honua/honua-gate-*:log-stream:*"
      Condition = {
        StringEquals = { "aws:SourceAccount" = var.member_account_id }
        ArnLike      = { "aws:SourceArn" = "arn:aws:logs:us-east-1:${var.member_account_id}:*" }
      }
    }]
  })
}

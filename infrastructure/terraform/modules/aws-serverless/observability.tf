# Serverless observability: X-Ray IAM, Lambda Insights, and an optional
# CloudWatch dashboard for the Honua demo Lambda. Everything here is gated on
# opt-in toggles (default off) so existing stacks are unaffected.

locals {
  dashboard_name        = "${local.name}-honua-serverless"
  honua_metrics_enabled = var.enable_dashboard && var.honua_metrics_namespace != ""
}

# --- Least-privilege X-Ray permissions ------------------------------------
# Only the segment-publish + sampling-read actions X-Ray active tracing needs.
data "aws_iam_policy_document" "lambda_xray" {
  count = var.enable_xray_tracing ? 1 : 0

  statement {
    sid    = "AllowXRayTraceSegments"
    effect = "Allow"
    actions = [
      "xray:PutTraceSegments",
      "xray:PutTelemetryRecords",
      "xray:GetSamplingRules",
      "xray:GetSamplingTargets",
      "xray:GetSamplingStatisticSummaries",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "lambda_xray" {
  count       = var.enable_xray_tracing ? 1 : 0
  name        = "${local.name}-lambda-xray"
  description = "Least-privilege X-Ray segment publishing for the Honua Lambda."
  policy      = data.aws_iam_policy_document.lambda_xray[0].json
  tags        = local.tags
}

resource "aws_iam_role_policy_attachment" "lambda_xray" {
  count      = var.enable_xray_tracing ? 1 : 0
  role       = aws_iam_role.lambda.name
  policy_arn = aws_iam_policy.lambda_xray[0].arn
}

# --- CloudWatch Lambda Insights -------------------------------------------
# AWS-managed policy; the Lambda Insights extension must be present in the
# image/layer for enhanced metrics to publish to the LambdaInsights namespace.
resource "aws_iam_role_policy_attachment" "lambda_insights" {
  count      = var.enable_lambda_insights ? 1 : 0
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchLambdaInsightsExecutionRolePolicy"
}

# --- CloudWatch dashboard --------------------------------------------------
resource "aws_cloudwatch_dashboard" "serverless" {
  count          = var.enable_dashboard ? 1 : 0
  dashboard_name = local.dashboard_name

  dashboard_body = jsonencode({
    widgets = concat(
      [
        {
          type   = "text"
          x      = 0
          y      = 0
          width  = 24
          height = 2
          properties = {
            markdown = "# Honua Serverless — ${local.name}\nLambda runtime, API Gateway, cold-start, X-Ray and custom Honua metrics for the demo stack."
          }
        },
        {
          type   = "metric"
          x      = 0
          y      = 2
          width  = 12
          height = 6
          properties = {
            title  = "Lambda duration (ms)"
            region = data.aws_region.current.name
            view   = "timeSeries"
            stat   = "Average"
            period = 60
            metrics = [
              ["AWS/Lambda", "Duration", "FunctionName", aws_lambda_function.this.function_name, { stat = "Average", label = "avg" }],
              ["...", { stat = "p90", label = "p90" }],
              ["...", { stat = "Maximum", label = "max" }],
            ]
          }
        },
        {
          type   = "metric"
          x      = 12
          y      = 2
          width  = 12
          height = 6
          properties = {
            title  = "Lambda errors & throttles"
            region = data.aws_region.current.name
            view   = "timeSeries"
            stat   = "Sum"
            period = 60
            metrics = [
              ["AWS/Lambda", "Errors", "FunctionName", aws_lambda_function.this.function_name],
              ["AWS/Lambda", "Throttles", "FunctionName", aws_lambda_function.this.function_name],
              ["AWS/Lambda", "Invocations", "FunctionName", aws_lambda_function.this.function_name],
            ]
          }
        },
        {
          type   = "metric"
          x      = 0
          y      = 8
          width  = 12
          height = 6
          properties = {
            title  = "Lambda concurrency"
            region = data.aws_region.current.name
            view   = "timeSeries"
            period = 60
            metrics = [
              ["AWS/Lambda", "ConcurrentExecutions", "FunctionName", aws_lambda_function.this.function_name, { stat = "Maximum" }],
              ["AWS/Lambda", "ProvisionedConcurrentExecutions", "FunctionName", aws_lambda_function.this.function_name, { stat = "Maximum" }],
              ["AWS/Lambda", "ProvisionedConcurrencyUtilization", "FunctionName", aws_lambda_function.this.function_name, { stat = "Maximum" }],
            ]
          }
        },
        {
          type   = "metric"
          x      = 12
          y      = 8
          width  = 12
          height = 6
          properties = {
            title  = "API Gateway requests & latency"
            region = data.aws_region.current.name
            view   = "timeSeries"
            period = 60
            metrics = [
              ["AWS/ApiGateway", "Count", "ApiId", aws_apigatewayv2_api.this.id, { stat = "Sum", label = "requests" }],
              ["AWS/ApiGateway", "5xx", "ApiId", aws_apigatewayv2_api.this.id, { stat = "Sum", label = "5xx" }],
              ["AWS/ApiGateway", "4xx", "ApiId", aws_apigatewayv2_api.this.id, { stat = "Sum", label = "4xx" }],
              ["AWS/ApiGateway", "Latency", "ApiId", aws_apigatewayv2_api.this.id, { stat = "p90", label = "latency p90", yAxis = "right" }],
            ]
          }
        },
      ],
      # Cold-start widget: prefer the custom Honua cold-start metric when the
      # custom namespace is wired; always show the Lambda Insights view when on.
      local.honua_metrics_enabled ? [
        {
          type   = "metric"
          x      = 0
          y      = 14
          width  = 12
          height = 6
          properties = {
            title  = "Cold starts & init duration (Honua custom metrics)"
            region = data.aws_region.current.name
            view   = "timeSeries"
            period = 60
            metrics = [
              [var.honua_metrics_namespace, "honua.lambda.cold_start", "function.name", aws_lambda_function.this.function_name, { stat = "Sum", label = "cold starts" }],
              [var.honua_metrics_namespace, "honua.lambda.init_duration_ms", "function.name", aws_lambda_function.this.function_name, { stat = "Average", label = "init ms", yAxis = "right" }],
            ]
          }
        },
      ] : [],
      var.enable_lambda_insights ? [
        {
          type   = "metric"
          x      = 12
          y      = 14
          width  = 12
          height = 6
          properties = {
            title  = "Lambda Insights — init & memory"
            region = data.aws_region.current.name
            view   = "timeSeries"
            period = 60
            metrics = [
              ["LambdaInsights", "init_duration", "function_name", aws_lambda_function.this.function_name, { stat = "Average", label = "init duration" }],
              ["LambdaInsights", "used_memory_max", "function_name", aws_lambda_function.this.function_name, { stat = "Maximum", label = "max memory used", yAxis = "right" }],
            ]
          }
        },
      ] : []
    )
  })
}

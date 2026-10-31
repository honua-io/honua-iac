# Bedrock tokens-per-minute quotas for the models the release harness and the cloud cells call.
# Applying this files a Service Quotas increase request; AWS may hold it for review. The request's
# status is in the `requests` output and in the Service Quotas console.

locals {
  quotas = merge(
    var.opus_5_5_tokens_per_minute > 0 ? {
      "opus-5-5-cross-region" = { code = "L-A4430697", value = var.opus_5_5_tokens_per_minute }
      "opus-5-5-global"       = { code = "L-A103A344", value = var.opus_5_5_tokens_per_minute }
    } : {},
    var.sonnet_5_5_tokens_per_minute > 0 ? {
      "sonnet-5-5-cross-region" = { code = "L-94A31E46", value = var.sonnet_5_5_tokens_per_minute }
      "sonnet-5-5-global"       = { code = "L-31AB82D0", value = var.sonnet_5_5_tokens_per_minute }
    } : {},
  )
}

resource "aws_servicequotas_service_quota" "bedrock" {
  for_each     = local.quotas
  service_code = "bedrock"
  quota_code   = each.value.code
  value        = each.value.value
}

output "requests" {
  description = "Quota code, requested value, and request status for each managed Bedrock quota."
  value = {
    for name, q in aws_servicequotas_service_quota.bedrock : name => {
      quota_code = q.quota_code
      requested  = q.value
      status     = try(q.request_status, null)
    }
  }
}

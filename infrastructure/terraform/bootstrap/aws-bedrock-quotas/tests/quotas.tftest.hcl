mock_provider "aws" {}

run "defaults_request_opus_and_sonnet" {
  command = plan
  assert {
    condition     = length(aws_servicequotas_service_quota.bedrock) == 4
    error_message = "defaults must manage the Opus 5.5 and Sonnet 5.5 quotas"
  }
  assert {
    condition     = aws_servicequotas_service_quota.bedrock["opus-5-5-cross-region"].quota_code == "L-A4430697" && aws_servicequotas_service_quota.bedrock["opus-5-5-global"].quota_code == "L-A103A344"
    error_message = "Opus 5.5 quota codes changed"
  }
  assert {
    condition     = aws_servicequotas_service_quota.bedrock["opus-5-5-cross-region"].value == 2000000
    error_message = "default Opus 5.5 TPM must be 2,000,000"
  }
  assert {
    condition     = aws_servicequotas_service_quota.bedrock["sonnet-5-5-cross-region"].quota_code == "L-94A31E46" && aws_servicequotas_service_quota.bedrock["sonnet-5-5-global"].quota_code == "L-31AB82D0"
    error_message = "Sonnet 5.5 quota codes changed"
  }
}

run "zero_manages_nothing" {
  command = plan
  variables {
    opus_5_5_tokens_per_minute   = 0
    sonnet_5_5_tokens_per_minute = 0
  }
  assert {
    condition     = length(aws_servicequotas_service_quota.bedrock) == 0
    error_message = "0 must leave quotas unmanaged"
  }
}

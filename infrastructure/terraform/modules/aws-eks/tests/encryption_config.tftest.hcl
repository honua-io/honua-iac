# Secret envelope-encryption contract for the EKS module (honua-iac#215).
#
# local.cluster_encryption_config is handed verbatim to the pinned
# terraform-aws-modules/eks module, which enables encryption_config only when the
# object is non-empty. Each run plans/applies the whole module (VPC + EKS) against
# mocked providers, so a type error in that expression fails here, offline, before a
# credentialed cell ever reaches `terraform plan`.

mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = {
      names = ["us-east-1a", "us-east-1b", "us-east-1c"]
    }
  }

  mock_data "aws_partition" {
    defaults = {
      dns_suffix         = "amazonaws.com"
      id                 = "aws"
      partition          = "aws"
      reverse_dns_prefix = "com.amazonaws"
    }
  }

  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
      arn        = "arn:aws:iam::123456789012:user/terraform-test"
      user_id    = "AIDATEST"
    }
  }

  mock_data "aws_iam_policy_document" {
    defaults = {
      json          = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
      minified_json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
}

mock_provider "tls" {}
mock_provider "time" {}
mock_provider "cloudinit" {}
mock_provider "null" {}

variables {
  name_prefix = "honua"
  environment = "test"
}

run "encryption_disabled" {
  command = plan

  variables {
    cluster_secret_encryption_enabled = false
  }

  assert {
    condition     = length(local.cluster_encryption_config) == 0
    error_message = "Disabled secret encryption must hand the EKS module an empty encryption config."
  }

  assert {
    condition     = length(aws_kms_key.eks) == 0
    error_message = "Disabled secret encryption must not create a CMK."
  }
}

run "encryption_disabled_ignores_supplied_key" {
  command = plan

  variables {
    cluster_secret_encryption_enabled = false
    cluster_secret_encryption_key_arn = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-0000000000bb"
  }

  assert {
    condition     = length(local.cluster_encryption_config) == 0 && length(aws_kms_key.eks) == 0
    error_message = "A supplied key ARN must not turn encryption on when it is disabled."
  }
}

run "encryption_module_owned_key" {
  command = plan

  # Pin the CMK ARN at plan time so the assertion compares known values.
  override_resource {
    target          = aws_kms_key.eks
    override_during = plan
    values = {
      arn = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-0000000000aa"
    }
  }

  variables {
    cluster_secret_encryption_enabled = true
  }

  assert {
    condition     = length(aws_kms_key.eks) == 1
    error_message = "Enabled encryption without a supplied key must create the module-owned CMK."
  }

  assert {
    condition     = local.cluster_encryption_config.provider_key_arn == "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-0000000000aa"
    error_message = "Envelope encryption must use the module-owned CMK."
  }

  assert {
    condition     = local.cluster_encryption_config.resources == ["secrets"]
    error_message = "Envelope encryption must cover Kubernetes secrets."
  }
}

run "encryption_supplied_key" {
  command = plan

  variables {
    cluster_secret_encryption_enabled = true
    cluster_secret_encryption_key_arn = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-0000000000bb"
  }

  assert {
    condition     = length(aws_kms_key.eks) == 0
    error_message = "A supplied key ARN must not mint a second CMK."
  }

  assert {
    condition     = local.cluster_encryption_config.provider_key_arn == "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-0000000000bb"
    error_message = "Envelope encryption must use the operator-supplied key."
  }

  assert {
    condition     = local.cluster_encryption_config.resources == ["secrets"]
    error_message = "Envelope encryption must cover Kubernetes secrets."
  }
}

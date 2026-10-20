# Opt-in until matching migration images and cloud execution are qualified.
# A migration function has no HTTP trigger, Redis credentials, license, admin
# API password, encryption master key, or authority to promote a serving alias.
data "aws_partition" "current" {}

locals {
  migration_enabled         = var.migration_image != null
  migration_function_arn    = "arn:${data.aws_partition.current.partition}:lambda:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:function:${local.name}-migration"
  migration_ec2_arn_prefix  = "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}"
  migration_network_actions = ["ec2:CreateNetworkInterface", "ec2:DescribeNetworkInterfaces", "ec2:DescribeSubnets", "ec2:DeleteNetworkInterface", "ec2:AssignPrivateIpAddresses", "ec2:UnassignPrivateIpAddresses"]
  migration_database_groups = local.migration_enabled ? {
    for key, value in var.additional_env : lower(replace(key, ":", "__")) => value...
    if contains(["database__schema", "database__defaultoperationalschema"], lower(replace(key, ":", "__"))) || can(regex("^database__operationalschemas__[0-9]+$", lower(replace(key, ":", "__"))))
  } : {}
  migration_database_environment = { for key, entries in local.migration_database_groups : key => entries[0] }
  migration_metadata_schemas     = try(local.migration_database_groups["database__schema"], [])
  migration_metadata_schema      = length(local.migration_metadata_schemas) == 0 ? "honua" : trimspace(local.migration_metadata_schemas[0])
  # On this explicitly checked ASCII subset, Terraform jsonencode and the
  # canonical .NET JSON string-array serializer produce identical UTF-8 bytes.
  # Existing databases with other names require a canonical caller-supplied hash;
  # never silently approximate .NET's escaping or normalize a database name.
  migration_locator_ascii = can(regex("^[A-Za-z0-9_.:-]+$", local.db_endpoint)) && can(regex("^[A-Za-z0-9_]+$", var.db_name)) && can(regex("^[A-Za-z_][A-Za-z0-9_]*$", local.migration_metadata_schema))
  migration_target_sha256 = var.migration_target_locator_sha256 != null ? var.migration_target_locator_sha256 : sha256(jsonencode([
    "honua.database-locator/v1", lower(replace(trimspace(local.db_endpoint), "/\\.+$/", "")),
    "5432", var.db_name, local.migration_metadata_schema
  ]))
  migration_environment = merge(local.migration_database_environment, {
    ASPNETCORE_ENVIRONMENT               = "Production"
    HONUA_MIGRATE_ONLY                   = "true"
    HONUA_MIGRATION_LAMBDA               = "true"
    HONUA_SKIP_MIGRATIONS                = "false"
    HONUA_MIGRATION_TARGET_SHA256        = local.migration_target_sha256
    HONUA_MIGRATION_MANIFEST_SHA256      = var.migration_packaged_manifest_sha256 != null ? var.migration_packaged_manifest_sha256 : ""
    ConnectionStrings__DefaultConnection = "aws:secretsmanager:${aws_secretsmanager_secret.connection_string.arn}?versionId=${aws_secretsmanager_secret_version.connection_string.version_id}"
  })
  migration_environment_encoded = base64encode(jsonencode(local.migration_environment))
  migration_environment_bytes   = length(local.migration_environment_encoded) * 3 / 4 - length(regexall("=", local.migration_environment_encoded))
}

resource "aws_iam_role" "migration" {
  count                = local.migration_enabled ? 1 : 0
  name_prefix          = "${local.name}-migration-"
  permissions_boundary = var.permissions_boundary_arn
  assume_role_policy   = data.aws_iam_policy_document.lambda_assume.json
  tags                 = local.tags
}

resource "aws_iam_role_policy" "migration" {
  count = local.migration_enabled ? 1 : 0
  name  = "${local.name}-migration"
  role  = aws_iam_role.migration[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadPinnedDatabaseConnection"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = [aws_secretsmanager_secret.connection_string.arn]
        Condition = {
          StringEquals = { "secretsmanager:VersionId" = aws_secretsmanager_secret_version.connection_string.version_id }
        }
      },
      {
        Sid      = "WriteMigrationLogs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = ["${aws_cloudwatch_log_group.migration[0].arn}:*"]
      },
      {
        # EC2 Describe APIs do not support resource-level permissions.
        Sid      = "DescribeVpcNetwork"
        Effect   = "Allow"
        Action   = ["ec2:DescribeNetworkInterfaces", "ec2:DescribeSubnets"]
        Resource = "*"
        Condition = {
          StringEquals = { "aws:RequestedRegion" = data.aws_region.current.name }
        }
      },
      {
        Sid    = "CreateVpcNetworkInterface"
        Effect = "Allow"
        Action = ["ec2:CreateNetworkInterface"]
        Resource = concat(
          ["${local.migration_ec2_arn_prefix}:network-interface/*", "${local.migration_ec2_arn_prefix}:security-group/${aws_security_group.lambda.id}"],
          [for subnet in local.private_subnets : "${local.migration_ec2_arn_prefix}:subnet/${subnet}"]
        )
        Condition = {
          StringEquals = { "aws:RequestedRegion" = data.aws_region.current.name }
        }
      },
      {
        Sid      = "MaintainVpcNetworkInterface"
        Effect   = "Allow"
        Action   = ["ec2:DeleteNetworkInterface", "ec2:AssignPrivateIpAddresses", "ec2:UnassignPrivateIpAddresses"]
        Resource = ["${local.migration_ec2_arn_prefix}:network-interface/*"]
        Condition = {
          StringEquals = { "aws:RequestedRegion" = data.aws_region.current.name }
          ArnEquals    = { "ec2:Vpc" = "${local.migration_ec2_arn_prefix}:vpc/${local.vpc_id}" }
        }
      },
      {
        # Lambda needs ENI permissions outside the execution environment, but
        # migration code must never use them. The unqualified source ARN is
        # required by Lambda; deriving it avoids a role/function dependency cycle.
        # https://docs.aws.amazon.com/lambda/latest/dg/configuration-vpc.html
        Sid      = "DenyFunctionCodeNetworkAdministration"
        Effect   = "Deny"
        Action   = local.migration_network_actions
        Resource = "*"
        Condition = {
          ArnEquals = { "lambda:SourceFunctionArn" = local.migration_function_arn }
        }
      }
    ]
  })
}

# Keep the optional writer policy separate so the main role's network/secret
# statements remain directly inspectable by static IAM policy checks.
resource "aws_iam_role_policy" "migration_tracing" {
  count = local.migration_enabled && var.enable_xray_tracing ? 1 : 0
  name  = "${local.name}-migration-tracing"
  role  = aws_iam_role.migration[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "WriteMigrationTraces"
      Effect   = "Allow"
      Action   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
      Resource = "*"
      Condition = {
        StringEquals = { "aws:RequestedRegion" = data.aws_region.current.name }
      }
    }]
  })
}

resource "aws_cloudwatch_log_group" "migration" {
  #checkov:skip=CKV_AWS_158: This preview profile uses CloudWatch's default encryption at rest; it does not provision a customer-managed log key.
  #checkov:skip=CKV_AWS_338: Retention follows the existing log_retention_days input; certification/demo callers may explicitly select shorter retention.
  count             = local.migration_enabled ? 1 : 0
  name              = "/aws/lambda/${local.name}-migration"
  retention_in_days = var.log_retention_days
  tags              = local.tags
}

resource "aws_lambda_function" "migration" {
  #checkov:skip=CKV_AWS_50: X-Ray follows the module's enable_xray_tracing option, default off.
  #checkov:skip=CKV_AWS_116: This function is invoked synchronously by Terraform; asynchronous DLQs do not capture its failures. The invocation postcondition blocks serving deployment.
  #checkov:skip=CKV_AWS_173: Environment values are secret references and configuration, encrypted with Lambda's default service key; this profile does not provision a customer-managed environment key.
  #checkov:skip=CKV_AWS_272: AWS Lambda code signing is unsupported for container images. This function requires a digest-pinned image and a matching packaged migration manifest.
  count         = local.migration_enabled ? 1 : 0
  function_name = "${local.name}-migration"
  role          = aws_iam_role.migration[0].arn
  package_type  = "Image"
  image_uri     = var.migration_image
  publish       = true
  architectures = var.lambda_architectures
  memory_size   = var.lambda_memory_size
  timeout       = 900
  # Canonical PostgreSQL migration locking remains authoritative across retries
  # and other runtimes. This also bounds concurrent invocations of this function.
  reserved_concurrent_executions = 1
  vpc_config {
    subnet_ids         = local.private_subnets
    security_group_ids = [aws_security_group.lambda.id]
  }
  dynamic "tracing_config" {
    for_each = var.enable_xray_tracing ? [1] : []
    content {
      mode = "Active"
    }
  }
  environment {
    variables = local.migration_environment
  }
  lifecycle {
    precondition {
      condition     = var.skip_migrations
      error_message = "The isolated migration function requires skip_migrations=true on serving functions."
    }
    precondition {
      condition     = var.migration_packaged_manifest_sha256 != null
      error_message = "Supply the canonical packaged migration manifest SHA-256 from the matching qualified server artifact."
    }
    precondition {
      condition     = var.migration_image == null ? true : split("@", var.migration_image)[0] == split("@", var.image)[0]
      error_message = "The migration image must come from the serving image's ECR repository, whose Lambda retrieval policy the module manages. Matching release provenance must also be verified before apply."
    }
    precondition {
      condition     = var.migration_target_locator_sha256 != null || local.migration_locator_ascii
      error_message = "Automatic locator hashing supports ASCII host/database/schema names only. Supply the canonical migration_target_locator_sha256 for other names or connection-option overrides."
    }
    precondition {
      condition     = alltrue([for entries in values(local.migration_database_groups) : length(entries) == 1])
      error_message = "Database settings must have unambiguous configuration keys, including casing and colon/double-underscore aliases."
    }
    precondition {
      condition     = local.migration_environment_bytes <= 4096
      error_message = "The isolated migration environment exceeds Lambda's 4 KB limit."
    }
  }
  depends_on = [
    aws_iam_role_policy.migration,
    aws_iam_role_policy.migration_tracing,
    aws_ecr_repository_policy.lambda_image_access,
    aws_security_group_rule.rds_from_lambda,
    aws_secretsmanager_secret_version.connection_string,
    null_resource.enable_postgis
  ]
  tags = local.tags
}

resource "random_uuid" "migration" {
  count = local.migration_enabled ? 1 : 0
  keepers = {
    function_version   = aws_lambda_function.migration[0].version
    connection_version = aws_secretsmanager_secret_version.connection_string.version_id
    target_sha256      = local.migration_target_sha256
    manifest_sha256    = var.migration_packaged_manifest_sha256
  }
}

resource "aws_lambda_invocation" "migration" {
  count           = local.migration_enabled ? 1 : 0
  function_name   = aws_lambda_function.migration[0].function_name
  qualifier       = aws_lambda_function.migration[0].version
  lifecycle_scope = "CREATE_ONLY"
  input = jsonencode({
    schemaVersion = "honua.migration-invocation/v1"
    runId         = random_uuid.migration[0].result
  })
  depends_on = [aws_vpc_endpoint.migration_secretsmanager, aws_vpc_endpoint.customcode_secretsmanager]
  lifecycle {
    postcondition {
      condition = try(
        jsondecode(self.result).schemaVersion == "honua.lambda-migration-run/v1" &&
        jsondecode(self.result).functionVersion == aws_lambda_function.migration[0].version &&
        jsondecode(self.result).invokedFunctionArn == "${aws_lambda_function.migration[0].arn}:${aws_lambda_function.migration[0].version}" &&
        length(jsondecode(self.result).requestId) > 0 &&
        jsondecode(self.result).migration.schemaVersion == "honua.migration-run/v1" &&
        jsondecode(self.result).migration.runId == random_uuid.migration[0].result &&
        jsondecode(self.result).migration.outcome == "completed" &&
        jsondecode(self.result).migration.provider == "postgres" &&
        jsondecode(self.result).migration.schemaVerified == true &&
        jsondecode(self.result).migration.targetLocatorSha256 == local.migration_target_sha256 &&
        jsondecode(self.result).migration.metadataSchema == local.migration_metadata_schema &&
        jsondecode(self.result).migration.packagedMigrationManifestSha256 == var.migration_packaged_manifest_sha256,
      false)
      error_message = "Migration did not return a verified receipt for this exact function version, run, database locator, schema and packaged manifest. Serving deployment is blocked."
    }
  }
}

# Private DNS must have one owner per service/VPC. Reuse the custom-code
# endpoint when enabled; operators may declare an existing VPC's endpoint.
resource "aws_security_group" "migration_secretsmanager" {
  #checkov:skip=CKV2_AWS_5: Attached by aws_vpc_endpoint.migration_secretsmanager[0].security_group_ids; both resources use the same conditional count.
  count       = local.migration_enabled && !var.enable_nat_gateway && !local.egress_isolation_enabled && var.migration_create_secretsmanager_endpoint ? 1 : 0
  name_prefix = "${local.name}-migration-vpce-"
  description = "Secrets Manager HTTPS from the migration function"
  vpc_id      = local.vpc_id
  ingress {
    description     = "Migration function resolves its pinned database secret"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [aws_security_group.lambda.id]
  }
  tags = local.tags
}

resource "aws_vpc_endpoint" "migration_secretsmanager" {
  count               = length(aws_security_group.migration_secretsmanager)
  vpc_id              = local.vpc_id
  service_name        = "com.amazonaws.${data.aws_region.current.name}.secretsmanager"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = local.private_subnets
  security_group_ids  = [aws_security_group.migration_secretsmanager[0].id]
  private_dns_enabled = true
  tags                = local.tags
}

output "migration_contract" {
  description = "Pinned migration invocation and verified provider response; null when the preview migration profile is disabled or the response is malformed. This is not a cloud qualification claim."
  # Explicitly protect the function response in this output. The installed
  # provider's result field is not itself marked Sensitive in its schema.
  sensitive = true
  # Invocation postconditions still block serving deployment on invalid receipts.
  # A malformed retained result must not also prevent planning its destruction.
  value = local.migration_enabled ? try({
    schemaVersion           = "honua.lambda-migration-binding/v1"
    servingImage            = var.image
    migrationImage          = var.migration_image
    functionArn             = aws_lambda_function.migration[0].arn
    functionVersion         = aws_lambda_function.migration[0].version
    connectionSecretArn     = aws_secretsmanager_secret.connection_string.arn
    connectionSecretVersion = aws_secretsmanager_secret_version.connection_string.version_id
    targetLocatorSha256     = local.migration_target_sha256
    packagedManifestSha256  = var.migration_packaged_manifest_sha256
    runId                   = random_uuid.migration[0].result
    receipt                 = jsondecode(aws_lambda_invocation.migration[0].result)
  }, null) : null
}

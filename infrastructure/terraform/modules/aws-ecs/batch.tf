locals {
  gp_batch_enabled    = var.gp_batch != null
  gp_batch_prefix     = trim(var.file_storage_aws_s3_key_prefix, "/")
  gp_batch_bucket_arn = "arn:${data.aws_partition.current.partition}:s3:::${local.file_storage_bucket_name}"
  gp_batch_environment = !local.gp_batch_enabled ? {} : {
    ControlPlane__TriggerMode                                       = "Poll"
    ControlPlane__ExecutionWorkloads__0__WorkloadId                 = "gp-batch"
    ControlPlane__ExecutionWorkloads__0__WorkloadName               = "GP Batch"
    ControlPlane__ExecutionWorkloads__0__TargetKind                 = "AwsBatch"
    ControlPlane__ExecutionWorkloads__0__Backend                    = "honua-aws-batch"
    ControlPlane__ExecutionWorkloads__0__Kind                       = "Geoprocessing"
    ControlPlane__ExecutionWorkloads__0__ArtifactReference          = var.gp_batch.image
    ControlPlane__ExecutionWorkloads__0__ParameterEntries__0__Key   = "batch.job_queue_arn"
    ControlPlane__ExecutionWorkloads__0__ParameterEntries__0__Value = aws_batch_job_queue.gp[0].arn
    ControlPlane__ExecutionWorkloads__0__ParameterEntries__1__Key   = "batch.job_definition_arn"
    ControlPlane__ExecutionWorkloads__0__ParameterEntries__1__Value = aws_batch_job_definition.gp[0].arn
  }
}

resource "terraform_data" "gp_batch_validation" {
  lifecycle {
    precondition {
      condition     = !local.gp_batch_enabled || (local.shared_file_storage_configured && local.gp_batch_prefix != "")
      error_message = "gp_batch requires shared AwsS3 file storage with a nonempty key prefix."
    }
    precondition {
      condition     = !local.gp_batch_enabled || !local.db_use_existing || try(var.gp_batch.database_security_group_id != null, false)
      error_message = "gp_batch with an external database requires database_security_group_id to admit workers on PostgreSQL port 5432."
    }
  }
}

resource "aws_security_group" "gp_batch" {
  #checkov:skip=CKV2_AWS_5: Attached to Batch Fargate tasks through the compute environment.
  count       = local.gp_batch_enabled ? 1 : 0
  name_prefix = "${local.name}-gp-"
  description = "Private GP Batch workers"
  vpc_id      = local.vpc_id
  egress {
    description = "HTTPS services via private subnet routing"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    description = "PostgreSQL via private subnet routing"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = local.tags
}

resource "aws_security_group_rule" "gp_batch_external_database" {
  count                    = local.gp_batch_enabled && local.db_use_existing ? 1 : 0
  type                     = "ingress"
  description              = "PostgreSQL from GP Batch workers"
  security_group_id        = var.gp_batch.database_security_group_id
  source_security_group_id = aws_security_group.gp_batch[0].id
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
}

resource "aws_iam_role" "gp_batch_execution" {
  count                = local.gp_batch_enabled ? 1 : 0
  name_prefix          = "${local.name}-gp-exec-"
  assume_role_policy   = data.aws_iam_policy_document.ecs_task_assume.json
  permissions_boundary = var.permissions_boundary_arn
  tags                 = local.tags
}

resource "aws_iam_role_policy_attachment" "gp_batch_execution" {
  count      = local.gp_batch_enabled ? 1 : 0
  role       = aws_iam_role.gp_batch_execution[0].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role" "gp_batch_job" {
  count                = local.gp_batch_enabled ? 1 : 0
  name_prefix          = "${local.name}-gp-job-"
  assume_role_policy   = data.aws_iam_policy_document.ecs_task_assume.json
  permissions_boundary = var.permissions_boundary_arn
  tags                 = local.tags
}

locals {
  gp_batch_secret_statements = [
    { Effect = "Allow", Action = ["secretsmanager:GetSecretValue"], Resource = [aws_secretsmanager_secret.db_connection.arn] },
    { Effect = "Allow", Action = ["kms:Decrypt"], Resource = [local.kms_key_arn], Condition = { StringEquals = { "kms:ViaService" = "secretsmanager.${data.aws_region.current.region}.${data.aws_partition.current.dns_suffix}", "kms:EncryptionContext:SecretARN" = aws_secretsmanager_secret.db_connection.arn } } }
  ]
}

resource "aws_iam_role_policy" "gp_batch_execution_secret" {
  count  = local.gp_batch_enabled ? 1 : 0
  role   = aws_iam_role.gp_batch_execution[0].id
  policy = jsonencode({ Version = "2012-10-17", Statement = local.gp_batch_secret_statements })
}

resource "aws_iam_role_policy" "gp_batch_job" {
  count = local.gp_batch_enabled ? 1 : 0
  role  = aws_iam_role.gp_batch_job[0].id
  policy = jsonencode({ Version = "2012-10-17", Statement = concat(local.gp_batch_secret_statements, [
    { Effect = "Allow", Action = ["s3:GetBucketLocation"], Resource = [local.gp_batch_bucket_arn] },
    { Effect = "Allow", Action = ["s3:ListBucket"], Resource = [local.gp_batch_bucket_arn], Condition = { StringLike = { "s3:prefix" = [local.gp_batch_prefix, "${local.gp_batch_prefix}/*"] } } },
    { Effect = "Allow", Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"], Resource = ["${local.gp_batch_bucket_arn}/${local.gp_batch_prefix}/*"] }
  ]) })
}

resource "aws_iam_role_policy" "gp_batch_submit" {
  count = local.gp_batch_enabled ? 1 : 0
  role  = aws_iam_role.task.id
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Effect = "Allow", Action = ["batch:SubmitJob"], Resource = [aws_batch_job_queue.gp[0].arn, aws_batch_job_definition.gp[0].arn] },
    # DescribeJobs/ListJobs lack resource-level IAM support; cancellation uses job ARNs.
    { Effect = "Allow", Action = ["batch:DescribeJobs", "batch:ListJobs"], Resource = ["*"] },
    { Effect = "Allow", Action = ["batch:CancelJob", "batch:TerminateJob"], Resource = ["arn:${data.aws_partition.current.partition}:batch:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:job/*"] }
  ] })
}

resource "aws_cloudwatch_log_group" "gp_batch" {
  count             = local.gp_batch_enabled ? 1 : 0
  name              = "/aws/batch/${local.name}-gp"
  retention_in_days = var.log_retention_days
  kms_key_id        = local.kms_key_arn
  tags              = local.tags
}

resource "aws_batch_compute_environment" "gp" {
  count       = local.gp_batch_enabled ? 1 : 0
  name_prefix = "${local.name}-gp-"
  type        = "MANAGED"
  state       = "ENABLED"
  compute_resources {
    type               = "FARGATE"
    max_vcpus          = var.gp_batch.max_vcpus
    subnets            = local.private_subnets
    security_group_ids = [aws_security_group.gp_batch[0].id]
  }
  lifecycle { create_before_destroy = true }
  tags = local.tags
}

resource "aws_batch_job_queue" "gp" {
  count    = local.gp_batch_enabled ? 1 : 0
  name     = "${local.name}-gp"
  state    = "ENABLED"
  priority = 1
  compute_environment_order {
    order               = 1
    compute_environment = aws_batch_compute_environment.gp[0].arn
  }
  tags = local.tags
}

resource "aws_batch_job_definition" "gp" {
  count                 = local.gp_batch_enabled ? 1 : 0
  name                  = "${local.name}-gp"
  type                  = "container"
  platform_capabilities = ["FARGATE"]
  container_properties = jsonencode({
    image                        = var.gp_batch.image
    executionRoleArn             = aws_iam_role.gp_batch_execution[0].arn
    jobRoleArn                   = aws_iam_role.gp_batch_job[0].arn
    resourceRequirements         = [{ type = "VCPU", value = "1" }, { type = "MEMORY", value = "2048" }]
    ephemeralStorage             = { sizeInGiB = var.gp_batch.scratch_gib }
    networkConfiguration         = { assignPublicIp = "DISABLED" }
    fargatePlatformConfiguration = { platformVersion = "LATEST" }
    runtimePlatform              = { cpuArchitecture = var.gp_batch.cpu_architecture, operatingSystemFamily = "LINUX" }
    secrets                      = [{ name = "ConnectionStrings__DefaultConnection", valueFrom = aws_secretsmanager_secret.db_connection.arn }]
    environment = [
      { name = "Licensing__Mode", value = "Disabled" },
      { name = "JobStore__WorkerMaxPoolSize", value = "2" },
      { name = "FileStorage__Provider", value = "AwsS3" },
      { name = "FileStorage__AwsS3__BucketName", value = local.file_storage_bucket_name },
      { name = "FileStorage__AwsS3__Region", value = local.file_storage_aws_s3_region },
      { name = "FileStorage__AwsS3__KeyPrefix", value = var.file_storage_aws_s3_key_prefix }
    ]
    logConfiguration = { logDriver = "awslogs", options = {
      awslogs-group         = aws_cloudwatch_log_group.gp_batch[0].name
      awslogs-region        = data.aws_region.current.region
      awslogs-stream-prefix = "gp"
    } }
  })
  retry_strategy { attempts = 1 }
  timeout { attempt_duration_seconds = 3600 }
  tags       = local.tags
  depends_on = [aws_iam_role_policy_attachment.gp_batch_execution, aws_iam_role_policy.gp_batch_execution_secret, aws_iam_role_policy.gp_batch_job, aws_secretsmanager_secret_version.db_connection]
}

output "gp_batch" {
  description = "Batch worker identifiers, or null when disabled."
  value = !local.gp_batch_enabled ? null : {
    queue_arn          = aws_batch_job_queue.gp[0].arn
    job_definition_arn = aws_batch_job_definition.gp[0].arn
    security_group_id  = aws_security_group.gp_batch[0].id
  }
}

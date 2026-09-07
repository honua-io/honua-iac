# Lambda GA certification substrate (honua-io/honua-release#282).
# The server lane owns the ephemeral functions and log groups, not Terraform.
# ecr:GetAuthorizationToken is granted in its own statement on Resource "*":
# AWS publishes no resource-level form for it. The token it returns is only an
# authentication credential; repository access stays governed by the scoped
# ecr:* statement, and the wildcard is confined to var.region.

data "aws_partition" "lambda_preview" {}

locals {
  lambda_preview_name = "honua-cert-cert-lambda-preview"
  lambda_preview_tags = merge(local.tags, {
    "honua-purpose" = "lambda-preview-certification"
  })
  lambda_preview_function_arn = "arn:${data.aws_partition.lambda_preview.partition}:lambda:${var.region}:${data.aws_caller_identity.current.account_id}:function:honua-certrun-lambda-*"
  lambda_preview_log_arn      = "arn:${data.aws_partition.lambda_preview.partition}:logs:${var.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/honua-certrun-lambda-*"
}

resource "aws_ecr_repository" "lambda_preview" {
  #checkov:skip=CKV_AWS_136: Reproducible certification images use ECR AES256 encryption; no customer-managed key is needed.
  name                 = local.lambda_preview_name
  image_tag_mutability = "IMMUTABLE"
  force_delete         = false

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = local.lambda_preview_tags
}

resource "aws_ecr_lifecycle_policy" "lambda_preview" {
  repository = aws_ecr_repository.lambda_preview.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the newest ${var.lambda_preview_image_retention_count} certification images"
      selection = {
        tagStatus     = "tagged"
        tagPrefixList = ["candidate-"]
        countType     = "imageCountMoreThan"
        countNumber   = var.lambda_preview_image_retention_count
      }
      action = { type = "expire" }
    }]
  })
}

# Preinstall the image retrieval policy so the runner cannot edit repository
# policies. Only Lambda functions in this account/region/run namespace may pull.
data "aws_iam_policy_document" "lambda_preview_image_pull" {
  statement {
    sid     = "LambdaCertificationImagePull"
    actions = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"]
    # ECR repository policies are resource-based and reject a Resource element
    # ("Invalid repository policy provided", first apply 2026-09-06); the
    # repository is implied by attachment.

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = [local.lambda_preview_function_arn]
    }
  }
}

resource "aws_ecr_repository_policy" "lambda_preview" {
  repository = aws_ecr_repository.lambda_preview.name
  policy     = data.aws_iam_policy_document.lambda_preview_image_pull.json
}

data "aws_iam_policy_document" "lambda_preview_trust" {
  statement {
    sid     = "LambdaServiceOnly"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

# AWSLambdaBasicExecutionRole has Resource "*". Its effective permissions are
# intersected with this boundary, restricting it to this lane's logs. The lane
# precreates log groups, so runtime CreateLogGroup is unnecessary. Beyond the
# ENI actions and read access to the cert stack's own secrets (below), no ECR,
# database, or other application permissions are granted to code.
data "aws_iam_policy_document" "lambda_preview_execution_boundary" {
  statement {
    sid       = "CertificationLogStreamsOnly"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${local.lambda_preview_log_arn}:log-stream:*"]
  }

  # The certification function is VPC-attached (it must reach the cert PostGIS
  # over private subnets, #4432); Lambda manages the ENIs with these actions,
  # which take no resource ARN (AWSLambdaVPCAccessExecutionRole shape).
  statement {
    sid = "CertificationVpcEni"
    actions = [
      "ec2:CreateNetworkInterface",
      "ec2:DescribeNetworkInterfaces",
      "ec2:DescribeSubnets",
      "ec2:DeleteNetworkInterface",
      "ec2:AssignPrivateIpAddresses",
      "ec2:UnassignPrivateIpAddresses",
    ]
    resources = ["*"]
  }

  # The candidate image boots with the standing function's environment, whose
  # aws:secretsmanager: references (connection string, admin password,
  # connection-encryption master key, optional Pro license) are resolved at
  # startup; without this the server exits before serving (run 34078979087:
  # "Failed to resolve the security setting 'HONUA_ADMIN_PASSWORD'"). Only the
  # cert stack's own secrets, by ARN; no KMS grant (secrets use the AWS-managed key).
  statement {
    sid       = "CertificationStackSecretsRead"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = local.lambda_preview_secret_arns
  }
}

locals {
  lambda_preview_secret_arns = compact([
    module.honua.db_connection_secret_arn,
    module.honua.admin_password_secret_arn,
    module.honua.master_key_secret_arn,
    module.honua.pro_license_secret_arn,
  ])
}

data "aws_iam_policy_document" "lambda_preview_execution_secrets" {
  statement {
    sid       = "CertificationStackSecretsRead"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = local.lambda_preview_secret_arns
  }
}

resource "aws_iam_role_policy" "lambda_preview_execution_secrets" {
  name   = "${local.lambda_preview_name}-execution-secrets"
  role   = aws_iam_role.lambda_preview_execution.id
  policy = data.aws_iam_policy_document.lambda_preview_execution_secrets.json
}

resource "aws_iam_policy" "lambda_preview_execution_boundary" {
  name   = "${local.lambda_preview_name}-execution-boundary"
  policy = data.aws_iam_policy_document.lambda_preview_execution_boundary.json
  tags   = local.lambda_preview_tags
}

resource "aws_iam_role" "lambda_preview_execution" {
  name                 = "${local.lambda_preview_name}-execution"
  assume_role_policy   = data.aws_iam_policy_document.lambda_preview_trust.json
  permissions_boundary = aws_iam_policy.lambda_preview_execution_boundary.arn
  tags                 = local.lambda_preview_tags
}

resource "aws_iam_role_policy_attachment" "lambda_preview_basic_execution" {
  role       = aws_iam_role.lambda_preview_execution.name
  policy_arn = "arn:${data.aws_partition.lambda_preview.partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "lambda_preview_vpc_access" {
  role       = aws_iam_role.lambda_preview_execution.name
  policy_arn = "arn:${data.aws_partition.lambda_preview.partition}:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

# A separate inline policy attaches to the EXISTING OIDC role. No inputs to the
# federation component or its trust policy change.
data "aws_iam_policy_document" "lambda_preview_certification" {
  # TagResource is required by CreateFunction with tags. Prevent that grant
  # from relabeling an already-owned function to bypass lifecycle conditions.
  dynamic "statement" {
    for_each = {
      PreserveCertificationRun     = "honua-cert-run"
      PreserveCertificationPurpose = "honua-purpose"
    }
    content {
      sid       = statement.key
      effect    = "Deny"
      actions   = ["lambda:TagResource"]
      resources = [local.lambda_preview_function_arn]

      condition {
        test     = "Null"
        variable = "aws:ResourceTag/${statement.value}"
        values   = ["false"]
      }

      condition {
        test     = "StringNotEquals"
        variable = "aws:RequestTag/${statement.value}"
        values   = ["&{aws:ResourceTag/${statement.value}}"]
      }
    }
  }

  statement {
    sid       = "CreateTaggedCertificationFunction"
    actions   = ["lambda:CreateFunction", "lambda:TagResource"]
    resources = [local.lambda_preview_function_arn]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/honua-purpose"
      values   = ["lambda-preview-certification"]
    }

    condition {
      test     = "StringLike"
      variable = "aws:RequestTag/honua-cert-run"
      values   = ["?*-?*"]
    }

    condition {
      test     = "ForAllValues:StringEquals"
      variable = "aws:TagKeys"
      values   = ["honua-cert-run", "honua-purpose"]
    }
  }

  # Read without tag conditions to detect collisions and verify deletion. These
  # reads cannot invoke, mutate, or remove a foreign/untagged function.
  statement {
    sid       = "ObserveCertificationFunction"
    actions   = ["lambda:GetFunction", "lambda:ListTags"]
    resources = [local.lambda_preview_function_arn]
  }

  statement {
    sid       = "InvokeAndDeleteTaggedCertificationFunction"
    actions   = ["lambda:InvokeFunction", "lambda:DeleteFunction"]
    resources = [local.lambda_preview_function_arn]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/honua-purpose"
      values   = ["lambda-preview-certification"]
    }

    condition {
      test     = "StringLike"
      variable = "aws:ResourceTag/honua-cert-run"
      values   = ["?*-?*"]
    }
  }

  # Candidate proof on the STANDING certification function (release#282 bill,
  # item 3): publish the certified digest as a new version, shift the alias,
  # verify through the alias Function URL, roll back, delete the version the
  # lane created. The driver reads the alias URL config before any write
  # ("AWS lambda get-function-url-config failed; serving noProof", first live
  # run 2026-09-06). Deletion is allowed on qualified (version) ARNs only,
  # never on the unqualified function.
  statement {
    sid = "CertifyStandingAliasUpgradeRollback"
    actions = [
      "lambda:GetFunction",
      "lambda:GetFunctionConfiguration",
      "lambda:GetFunctionUrlConfig",
      "lambda:GetAlias",
      "lambda:ListAliases",
      "lambda:ListVersionsByFunction",
      "lambda:UpdateFunctionCode",
      "lambda:PublishVersion",
      "lambda:UpdateAlias",
      "lambda:InvokeFunction",
      "lambda:InvokeFunctionUrl",
    ]
    resources = [
      module.honua.lambda_function_arn,
      "${module.honua.lambda_function_arn}:*",
    ]
  }

  statement {
    sid       = "DeleteOnlyStandingFunctionVersions"
    actions   = ["lambda:DeleteFunction"]
    resources = ["${module.honua.lambda_function_arn}:*"]
  }

  # Creating a VPC-attached function makes Lambda validate the subnets and
  # security groups with the CALLER's credentials (AccessDeniedException "denied
  # by EC2", eighth live run 2026-09-07). Read-only Describe actions take no
  # resource ARN.
  statement {
    sid = "CertificationVpcDescribe"
    actions = [
      "ec2:DescribeSubnets",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeVpcs",
      "ec2:DescribeNetworkInterfaces",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "PassOnlyCertificationExecutionRole"
    actions   = ["iam:PassRole"]
    resources = [aws_iam_role.lambda_preview_execution.arn]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["lambda.amazonaws.com"]
    }
  }

  # `aws ecr get-login-password` needs a registry authorization token before any
  # push. AWS supports this action ONLY on Resource "*" -- it is registry-wide
  # and has no repository ARN form:
  # https://docs.aws.amazon.com/service-authorization/latest/reference/list_ecr.html
  # The wildcard is unavoidable and is not a widening of repository access: the
  # token authenticates the Docker client but authorizes nothing on its own, and
  # every repository operation remains bound to the certification repository ARN
  # by MirrorAndVerifyCertificationImage below. Keep it in its own statement and
  # confine it to the certification region so it cannot be exercised against
  # registries in any other region.
  statement {
    #checkov:skip=CKV_AWS_356: ecr:GetAuthorizationToken has no resource-level ARN form; scoped by aws:RequestedRegion.
    sid       = "EcrAuthorizationTokenGlobal"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.region]
    }
  }

  # Reruns for the same candidate must be able to replace a stale mirror tag
  # (the repository is tag-immutable; first live rerun 2026-09-06 failed with
  # TAG_INVALID). Scoped to the certification repository only.
  statement {
    sid       = "ReplaceStaleCertificationMirrorTag"
    actions   = ["ecr:DescribeImages", "ecr:BatchDeleteImage"]
    resources = [aws_ecr_repository.lambda_preview.arn]
  }

  statement {
    sid = "MirrorAndVerifyCertificationImage"
    actions = [
      "ecr:DescribeImages",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:GetRepositoryPolicy",
      "ecr:BatchCheckLayerAvailability",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage"
    ]
    resources = [aws_ecr_repository.lambda_preview.arn]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/honua-purpose"
      values   = ["lambda-preview-certification"]
    }
  }

  # The current script creates UNTAGGED groups. Tag conditions would deny its
  # calls. DescribeLogGroups is already in the component's CloudWatchReadGlobal;
  # no new global read grant is added here.
  statement {
    sid = "CertificationLogGroupLifecycle"
    actions = [
      "logs:CreateLogGroup",
      "logs:PutRetentionPolicy",
      "logs:FilterLogEvents",
      "logs:DeleteLogGroup"
    ]
    resources = ["${local.lambda_preview_log_arn}:*"]
  }
}

resource "aws_iam_role_policy" "lambda_preview_certification" {
  name   = "${local.lambda_preview_name}-certification"
  role   = module.github_oidc.role_name
  policy = data.aws_iam_policy_document.lambda_preview_certification.json
}

# Function URL on the standing certification alias (release#282 bill, item 2):
# the certification driver verifies REALAWS_CERT_LAMBDA_WRITE_BASE_URL against
# `get-function-url-config --qualifier <alias>` before any write, so the write
# target must be the alias's own URL, never the API Gateway or the demo.
# NONE auth: the server authenticates every request itself with X-API-Key.
resource "aws_lambda_function_url" "cert_alias" {
  function_name      = module.honua.lambda_function_name
  qualifier          = module.honua.lambda_alias_name
  authorization_type = "NONE"
}

resource "aws_lambda_permission" "cert_alias_function_url" {
  statement_id           = "AllowCertificationFunctionUrlInvoke"
  action                 = "lambda:InvokeFunctionUrl"
  function_name          = module.honua.lambda_function_name
  qualifier              = module.honua.lambda_alias_name
  principal              = "*"
  function_url_auth_type = "NONE"
}

output "REALAWS_CERT_LAMBDA_WRITE_BASE_URL" {
  description = "Function URL of the standing certification alias; set as the honua-server repository variable of the same name."
  value       = aws_lambda_function_url.cert_alias.function_url
}

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
    sid       = "LambdaCertificationImagePull"
    actions   = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"]
    resources = [aws_ecr_repository.lambda_preview.arn]

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
# precreates log groups, so runtime CreateLogGroup is unnecessary. No VPC/ENI,
# ECR, database, secret, or other application permissions are granted to code.
data "aws_iam_policy_document" "lambda_preview_execution_boundary" {
  statement {
    sid       = "CertificationLogStreamsOnly"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${local.lambda_preview_log_arn}:log-stream:*"]
  }
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

###############################################################################
# Lambda Preview real-deployment certification bootstrap (honua-iac#168).
#
# These are standing bootstrap resources. The honua-server lane mirrors the
# exact candidate into this immutable repository, creates one uniquely named
# honua-certrun-lambda-* function and matching log group, verifies it, and
# deletes only those per-run resources. The GitHub OIDC trust policy is not
# changed; only the cert role's resource-scoped permission policy is extended.
###############################################################################

locals {
  lambda_preview_run_prefix = "honua-certrun-lambda"
}

resource "aws_ecr_repository" "lambda_preview" {
  name                 = "${local.name}-lambda-preview"
  image_tag_mutability = "IMMUTABLE"

  encryption_configuration {
    # AWS-managed ECR KMS key: policy-compliant encryption without adding a
    # customer-managed key or expanding the certification role's permissions.
    encryption_type = "KMS"
  }

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = merge(local.tags, {
    Purpose = "lambda-preview-certification"
  })
}

resource "aws_ecr_lifecycle_policy" "lambda_preview" {
  repository = aws_ecr_repository.lambda_preview.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Expire untagged mirror layers after seven days"
      selection = {
        tagStatus   = "untagged"
        countType   = "sinceImagePushed"
        countUnit   = "days"
        countNumber = 7
      }
      action = { type = "expire" }
    }]
  })
}

data "aws_iam_policy_document" "lambda_preview_ecr_access" {
  statement {
    sid    = "AllowLambdaPreviewImageRetrieval"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }

    actions = [
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer"
    ]

    condition {
      test     = "StringLike"
      variable = "aws:sourceArn"
      values = [
        "arn:aws:lambda:${var.region}:${data.aws_caller_identity.current.account_id}:function:${local.lambda_preview_run_prefix}-*"
      ]
    }
  }
}

resource "aws_ecr_repository_policy" "lambda_preview" {
  repository = aws_ecr_repository.lambda_preview.name
  policy     = data.aws_iam_policy_document.lambda_preview_ecr_access.json
}

data "aws_iam_policy_document" "lambda_preview_execution_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda_preview_execution" {
  name               = "${local.name}-lambda-preview-exec"
  assume_role_policy = data.aws_iam_policy_document.lambda_preview_execution_trust.json
  tags               = local.tags
}

data "aws_iam_policy_document" "lambda_preview_execution" {
  statement {
    sid    = "WriteOnlyRunLogStreams"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]
    resources = [
      "arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${local.lambda_preview_run_prefix}-*:log-stream:*"
    ]
  }
}

resource "aws_iam_role_policy" "lambda_preview_execution" {
  name   = "write-certification-logs"
  role   = aws_iam_role.lambda_preview_execution.id
  policy = data.aws_iam_policy_document.lambda_preview_execution.json
}

data "aws_iam_policy_document" "lambda_preview_certification" {
  statement {
    sid    = "MirrorCandidate"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:CompleteLayerUpload",
      "ecr:DescribeImages",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart"
    ]
    resources = [aws_ecr_repository.lambda_preview.arn]
  }

  #checkov:skip=CKV_AWS_356: GetAuthorizationToken has no resource-level ARN.
  statement {
    sid       = "LoginToEcr"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid    = "OwnRunFunctionLifecycle"
    effect = "Allow"
    actions = [
      "lambda:CreateFunction",
      "lambda:DeleteFunction",
      "lambda:GetFunction",
      "lambda:GetFunctionConfiguration",
      "lambda:InvokeFunction",
      "lambda:ListTags",
      "lambda:TagResource",
      "lambda:UntagResource"
    ]
    resources = [
      "arn:aws:lambda:${var.region}:${data.aws_caller_identity.current.account_id}:function:${local.lambda_preview_run_prefix}-*"
    ]
  }

  statement {
    sid       = "PassDedicatedExecutionRole"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = [aws_iam_role.lambda_preview_execution.arn]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["lambda.amazonaws.com"]
    }
  }

  statement {
    sid    = "OwnRunLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:DeleteLogGroup",
      "logs:DescribeLogStreams",
      "logs:FilterLogEvents",
      "logs:GetLogEvents",
      "logs:PutRetentionPolicy"
    ]
    resources = [
      "arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${local.lambda_preview_run_prefix}-*",
      "arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${local.lambda_preview_run_prefix}-*:*"
    ]
  }
}

resource "aws_iam_role_policy" "lambda_preview_certification" {
  name   = "lambda-preview-certification"
  role   = module.github_oidc.role_name
  policy = data.aws_iam_policy_document.lambda_preview_certification.json
}

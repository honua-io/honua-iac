# Opt-in grants for the product release executor running as this function's execution role.
# Republishes the current image and moves the alias. It does not change configuration or secrets,
# and it does not assume the standing update-rollback controller.
variable "product_release_executor" {
  description = "Attach the product release executor policy to this cell's Lambda execution role. Default false. The release session sets this; a product lane must not apply it."
  type        = bool
  default     = false
}

resource "aws_iam_role_policy" "product_release_executor" {
  count = var.product_release_executor ? 1 : 0
  name  = "${local.name}-product-release-executor"
  role  = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "PublishCellFunctionImage"
        Effect = "Allow"
        Action = [
          "lambda:GetFunction",
          "lambda:GetFunctionConfiguration",
          "lambda:GetAlias",
          "lambda:UpdateFunctionCode",
          "lambda:PublishVersion",
          "lambda:UpdateAlias",
        ]
        Resource = [
          aws_lambda_function.this.arn,
          "${aws_lambda_function.this.arn}:*",
        ]
      },
    ]
  })
}

# ---------------------------------------------------------------------------
# Shared file storage on S3 (file_storage_provider = "AwsS3").
#
# honua-server dispatches a background file import to the durable runner, which
# on this module is the GP Batch workload (honua-server#5916). The API Lambda
# stages the uploaded file through FileStorage and the Batch worker reads it, so
# both must use the same bucket; with the server's default Local provider the
# server refuses background imports with 503 (reasonCode
# shared-file-storage-required). local.file_storage_environment (main.tf)
# renders FileStorage__* on the API Lambda, the control-plane event functions and
# every GP Batch job-definition tier; this file grants each of those roles the
# same access to the bucket. The bucket is operator-owned: the module does not
# create it.
#
# Object actions are scoped to keys under file_storage_aws_s3_key_prefix (the
# server writes every object under it, CloudStoragePath.BuildPrefix), so cells
# sharing one bucket under different prefixes cannot touch each other's objects.
# Bucket-level actions (ListBucket, multipart listing, GetBucketLocation) take
# the bucket ARN, as in modules/aws-ecs. The control-plane event functions get
# the grant because they carry the same environment and run the file-storage
# cleanup tick (FileStorageCleanup).
#
# The custom-code provisioning job (egress-isolation.tf) restores dependencies
# only and never opens FileStorage, so it gets neither the environment nor the
# grant; the custom-code job definitions (customcode-batch.tf) keep their empty
# environment by design.
# ---------------------------------------------------------------------------

locals {
  file_storage_bucket_arn = "arn:${split(":", data.aws_caller_identity.current.arn)[1]}:s3:::${var.file_storage_aws_s3_bucket_name}"
  file_storage_key_prefix = trim(var.file_storage_aws_s3_key_prefix, "/")
  file_storage_object_arn = local.file_storage_key_prefix != "" ? "${local.file_storage_bucket_arn}/${local.file_storage_key_prefix}/*" : "${local.file_storage_bucket_arn}/*"

  file_storage_s3_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "FileStorageBucket"
        Effect = "Allow"
        Action = [
          "s3:GetBucketLocation",
          "s3:ListBucket",
          "s3:ListBucketMultipartUploads"
        ]
        Resource = [local.file_storage_bucket_arn]
      },
      {
        Sid    = "FileStorageObjects"
        Effect = "Allow"
        Action = [
          "s3:AbortMultipartUpload",
          "s3:DeleteObject",
          "s3:GetObject",
          "s3:ListMultipartUploadParts",
          "s3:PutObject"
        ]
        Resource = [local.file_storage_object_arn]
      }
    ]
  })
}

resource "aws_iam_role_policy" "lambda_file_storage_s3" {
  count  = local.file_storage_shared ? 1 : 0
  name   = "${local.name}-file-storage-s3"
  role   = aws_iam_role.lambda.id
  policy = local.file_storage_s3_policy
}

resource "aws_iam_role_policy" "control_plane_events_file_storage_s3" {
  count  = local.file_storage_shared && local.control_plane_events_enabled ? 1 : 0
  name   = "${local.name}-cp-evt-file-storage-s3"
  role   = aws_iam_role.control_plane_events[0].id
  policy = local.file_storage_s3_policy
}

resource "aws_iam_role_policy" "batch_job_file_storage_s3" {
  count  = local.file_storage_shared && local.gp_batch_enabled ? 1 : 0
  name   = "${local.gp_batch_name}-job-file-storage-s3"
  role   = aws_iam_role.batch_job[0].id
  policy = local.file_storage_s3_policy
}

###############################################################################
# honua-worker-etl Batch substrate (ADR-0038 roadmap F).
#
# The heavyweight GP/ETL worker image (honua-worker-etl) is the GDAL + PDAL +
# PROJ equipped, NATIVE-runtime-profile counterpart to the lean serving image.
# It runs the SAME durable job-execution loop and submits into the SAME Batch
# substrate the GP family already provisions (the Fargate-Spot scale-to-zero
# compute environment, job queue, IAM roles, and job-definition size POOL in
# batch.tf) — a native-profile job is just a job whose container image is the
# worker-etl image and whose RuntimeProfile = "native". What the worker-etl
# image needs that the GP path does not provision is its OWN ECR repository, so
# the heavyweight image has a lifecycle decoupled from both the Honua Lambda
# image and the worker-gdal image.
#
# This file therefore mirrors the worker-gdal ECR repository + lifecycle policy
# in batch.tf with identical hardening — real KMS encryption (AWS-managed ECR
# key, so there is no CMK to manage and the policy gate is satisfied without a
# cross-module checkov skip), scan-on-push, IMMUTABLE tags by default, and an
# image-count lifecycle cap — under its own create flag so existing deploys are
# unchanged unless an operator opts in.
#
# Toggled off by default (create_worker_etl_repo = false). The repository name
# is stable regardless of the flag so an operator can pre-create + push, then
# flip the flag on.
###############################################################################

locals {
  # worker-etl ECR repository name is stable whether or not it is created, so an
  # operator can pre-create + push, then flip create_worker_etl_repo on. Mirrors
  # the worker_gdal_repo_name convention in batch.tf.
  worker_etl_repo_name = "${local.name}-worker-etl"
}

# ---------------------------------------------------------------------------
# Dedicated worker-etl ECR repository (optional).
# Gives the heavyweight GDAL/PDAL/PROJ ETL worker image its own lifecycle,
# decoupled from the Honua Lambda image and the worker-gdal image. Off by
# default (create_worker_etl_repo = false). Scan-on-push is enabled; encryption
# uses KMS with the AWS-managed ECR key (no external CMK dependency); a lifecycle
# policy caps retained images.
# ---------------------------------------------------------------------------

resource "aws_ecr_repository" "worker_etl" {
  count                = var.create_worker_etl_repo ? 1 : 0
  name                 = local.worker_etl_repo_name
  image_tag_mutability = var.worker_etl_repo_image_tag_mutability
  force_delete         = var.worker_etl_repo_force_delete

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    # KMS with the AWS-managed ECR key (no CMK to manage). An inline checkov
    # skip in this module is not honored when the repo is evaluated through the
    # examples/aws-cert module instantiation, so use the real KMS setting —
    # identical to the worker-gdal repository in batch.tf.
    encryption_type = "KMS"
  }

  tags = local.tags
}

# Expire all but the most-recent N images so the worker-etl repo does not
# accumulate storage cost across job-specific tags.
resource "aws_ecr_lifecycle_policy" "worker_etl" {
  count      = var.create_worker_etl_repo ? 1 : 0
  repository = aws_ecr_repository.worker_etl[0].name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Retain only the most recent ${var.worker_etl_repo_max_image_count} images."
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = var.worker_etl_repo_max_image_count
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}

# Gate stacks run current server builds before a public image exists: the lane
# pushes a cohort image here and a gate stack pulls it by digest through
# ServerImageUri and the template's private repository ARN parameter, which
# grants its execution role the pull actions. Tags are immutable, so a digest
# keeps meaning one image. ECR-managed AES256, not a KMS key, for the same
# reason as the template bucket: no KMS grant has to pass the lane boundary or
# the shared-account fences. No repository policy: gate roles are fenced by
# identity (the workload boundary allows only the four pull actions on ECR and
# the service role none that write). Other principals in a shared account with
# account-wide ECR rights can still read or delete these images; digests and
# immutable tags keep integrity, and the images are pre-release builds of the
# public server, not secrets.
locals {
  server_repository       = "honua-gate/server"
  server_repository_arn   = "arn:aws:ecr:us-east-1:${var.member_account_id}:repository/${local.server_repository}"
  boundary_repository_arn = "arn:aws:ecr:*:${var.member_account_id}:repository/${local.server_repository}"
  # AWS owns this repository, so it carries no gate stack tag. The account is the
  # us-east-1 entry of the Launch Stack GuardDutyAgent map.
  guardduty_agent_repository_arn = "arn:aws:ecr:us-east-1:593207742271:repository/aws-guardduty-agent-fargate"

  # Covers the gate cohorts in flight: an expired digest breaks the next task
  # replacement of a live gate stack that still references it.
  kept_server_images = 20

  image_push_actions = [
    "ecr:BatchCheckLayerAvailability", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart",
    "ecr:CompleteLayerUpload", "ecr:PutImage", "ecr:DescribeImages", "ecr:BatchGetImage"
  ]
}
resource "aws_ecr_repository" "server" {
  name                 = local.server_repository
  image_tag_mutability = "IMMUTABLE"
  image_scanning_configuration { scan_on_push = true }
  encryption_configuration { encryption_type = "AES256" }
}
resource "aws_ecr_lifecycle_policy" "server" {
  repository = aws_ecr_repository.server.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1, description = "Keep the newest ${local.kept_server_images} images"
      selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = local.kept_server_images }
      action       = { type = "expire" }
    }]
  })
}
output "server_repository_uri" {
  value       = aws_ecr_repository.server.repository_url
  sensitive   = true
  description = "Private gate server image repository; push a cohort image with a new tag and pass <uri>@<digest> as ServerImageUri. Never publish in PR text."
}

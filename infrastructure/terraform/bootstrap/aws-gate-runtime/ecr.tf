# Gate stacks run current server builds before a public image exists: the lane
# pushes a cohort image here and a gate stack pulls it by digest through
# ServerImageUri and the template's private repository ARN parameter, which
# grants its execution role the pull actions. Tags are immutable, so a digest
# keeps meaning one image. ECR-managed AES256, not a KMS key, for the same
# reason as the template bucket: no KMS grant has to pass the lane boundary or
# the shared-account fences. No repository policy: the workload boundary allows
# only the four pull actions on ECR and the service role none that write.
locals {
  server_repository     = "honua-gate/server"
  server_repository_arn = "arn:aws:ecr:us-east-1:${var.member_account_id}:repository/${local.server_repository}"
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
      rulePriority = 1, description = "Keep the newest 20 images"
      selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 20 }
      action       = { type = "expire" }
    }]
  })
}
output "server_repository_uri" {
  value       = aws_ecr_repository.server.repository_url
  sensitive   = true
  description = "Private gate server image repository; push a cohort image with a new tag and pass <uri>@<digest> as ServerImageUri. Never publish in PR text."
}

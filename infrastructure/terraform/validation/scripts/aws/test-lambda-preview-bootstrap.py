from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[3]
STACK = (ROOT / "examples/aws-cert/lambda-preview-cert.tf").read_text(encoding="utf-8")
OIDC = (ROOT / "components/aws-github-oidc/main.tf").read_text(encoding="utf-8")


class LambdaPreviewBootstrapContractTests(unittest.TestCase):
    def test_trust_remains_pinned_to_existing_subject_input(self):
        trust = OIDC[OIDC.index('data "aws_iam_policy_document" "trust"') : OIDC.index('resource "aws_iam_role" "github_actions"')]
        self.assertIn('variable = "token.actions.githubusercontent.com:sub"', trust)
        self.assertIn("values   = local.oidc_subjects", trust)
        self.assertNotIn("lambda_preview", trust)

    def test_mirror_and_run_permissions_are_resource_scoped(self):
        self.assertIn("resources = [aws_ecr_repository.lambda_preview.arn]", STACK)
        self.assertIn("function:${local.lambda_preview_run_prefix}-*", STACK)
        self.assertIn("resources = [aws_iam_role.lambda_preview_execution.arn]", STACK)
        self.assertIn('values   = ["lambda.amazonaws.com"]', STACK)

    def test_standing_resources_are_dedicated_and_immutable(self):
        self.assertIn('name                 = "${local.name}-lambda-preview"', STACK)
        self.assertIn('image_tag_mutability = "IMMUTABLE"', STACK)
        self.assertIn('encryption_type = "KMS"', STACK)
        self.assertIn('identifiers = ["lambda.amazonaws.com"]', STACK)
        self.assertIn('lambda_preview_run_prefix = "honua-certrun-lambda"', STACK)

    def test_permissions_attach_without_modifying_oidc_trust(self):
        self.assertIn("role   = module.github_oidc.role_name", STACK)
        self.assertNotIn("lambda_preview", OIDC)


if __name__ == "__main__":
    unittest.main()

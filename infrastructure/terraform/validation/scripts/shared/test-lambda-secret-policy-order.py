#!/usr/bin/env python3
"""Check explicit Terraform publication edges for version-pinned Lambda secrets."""

from pathlib import Path
import re


MODULE = Path(__file__).resolve().parents[3] / "modules" / "aws-serverless"


def dependencies(source: Path, kind: str, name: str) -> set[str]:
    text = source.read_text()
    resource = re.search(
        rf'^resource "{re.escape(kind)}" "{re.escape(name)}" \{{(.*?)^\}}',
        text,
        re.MULTILINE | re.DOTALL,
    )
    if resource is None:
        raise AssertionError(f"missing {kind}.{name} in {source}")
    depends = re.search(r"^  depends_on\s*=\s*\[(.*?)\]", resource.group(1), re.MULTILINE | re.DOTALL)
    if depends is None:
        raise AssertionError(f"missing explicit depends_on for {kind}.{name}")
    return set(re.findall(r"\b(?:aws_iam_[a-z_]+|terraform_data)\.[a-z_]+\b", depends.group(1)))


api = dependencies(MODULE / "main.tf", "aws_lambda_function", "this")
required_api = {
    "aws_iam_role_policy_attachment.lambda_secrets",
    "aws_iam_role_policy.lambda_request_secret_references",
}
if not required_api <= api:
    raise AssertionError(f"API Lambda can publish before secret grants: {required_api - api}")

required_events = {
    "aws_iam_role_policy.control_plane_events",
    "aws_iam_role_policy.control_plane_events_request_secret_references",
}
for name in ("control_plane_reconcile", "control_plane_backstop", "control_plane_tick"):
    actual = dependencies(MODULE / "control-plane-events.tf", "aws_lambda_function", name)
    if not required_events <= actual:
        raise AssertionError(f"{name} can publish before secret grants: {required_events - actual}")

print("Lambda version publication waits for its actual secret IAM policy resources")

settings = dependencies(MODULE / "runtime-settings.tf", "aws_secretsmanager_secret", "runtime_settings")
if "terraform_data.lambda_secrets_policy_budget" not in settings:
    raise AssertionError("immutable runtime settings can be created before the plan-known IAM budget guard")

print("Immutable runtime settings wait for the plan-known policy budget guard")

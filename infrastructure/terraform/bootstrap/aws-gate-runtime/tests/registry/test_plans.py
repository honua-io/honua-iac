"""Only the fully fenced shared-account Terraform plan can certify the gate."""
import json
from pathlib import Path
import tempfile
import unittest
from audit import rendered_statements


class RenderedPlanTests(unittest.TestCase):
    def plan(self, run, effect):
        resources = [{"address": address, "type": kind, "change": {"after": {
            "policy": json.dumps({"Statement": [{"Effect": effect, "Action": "*", "Resource": "*"}]})}}}
            for address, kind in [("aws_iam_role_policy.cloudformation", "aws_iam_role_policy"),
                                  ("aws_iam_policy.cloudformation_fences", "aws_iam_policy")]]
        return {"@testrun": run, "test_plan": {"resource_changes": resources}}

    def test_member_plans_cannot_overwrite_the_shared_account_fences(self):
        plans = [self.plan("shared_account_policy_quotas_with_deployment_sized_inputs", "Deny"),
                 self.plan("orphan_cleanup_explicit_opt_in", "Allow")]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "plans.jsonl"
            path.write_text("\n".join(map(json.dumps, plans)))
            self.assertTrue(all(s["Effect"] == "Deny" for s in rendered_statements(path)))

    def test_a_member_only_plan_cannot_certify_shared_account_permissions(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "plans.jsonl"
            path.write_text(json.dumps(self.plan("member_account_bootstrap_pool_is_protected", "Allow")))
            with self.assertRaises(ValueError):
                rendered_statements(path)


if __name__ == "__main__":
    unittest.main()

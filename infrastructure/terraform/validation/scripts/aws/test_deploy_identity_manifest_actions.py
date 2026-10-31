"""Checks that action patterns cannot enter a deploy-identity manifest."""
import importlib.util
from pathlib import Path
import unittest

path = Path(__file__).with_name("generate-deploy-identity-manifests.py")
spec = importlib.util.spec_from_file_location("deploy_identity_manifests", path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class WildcardActionTests(unittest.TestCase):
    def test_checks_every_action_field(self):
        manifest = {
            "id": "test",
            "region_actions": ["ecs:Create*"],
            "global_actions": ["route53:Get?"],
            "iam_statements": [{"actions": ["iam:List*"]}],
            "simulate_allow": ["lambda:Get?"],
        }
        self.assertEqual(len(module.wildcard_action_problems(manifest)), 4)

    def test_accepts_exact_actions(self):
        manifest = {
            "id": "test",
            "region_actions": ["ecs:CreateCluster"],
            "global_actions": [],
            "iam_statements": [{"actions": ["iam:GetRole"]}],
        }
        self.assertEqual(module.wildcard_action_problems(manifest), [])


if __name__ == "__main__":
    unittest.main()

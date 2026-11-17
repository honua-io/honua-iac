"""Authorization edge cases that must never turn a missing grant into a pass."""
import unittest

from iam import condition_value, decision


class AuthorizationTests(unittest.TestCase):
    def test_explicit_deny_wins_regardless_of_statement_order(self):
        allow = {"Effect": "Allow", "Action": "rds:*", "Resource": "*"}
        deny = {"Effect": "Deny", "Action": "RDS:AddTagsToResource", "Resource": "*"}
        request = ("rds:AddTagsToResource", "arn:synthetic", {})
        for statements in ([allow, deny], [deny, allow]):
            self.assertEqual("Deny", decision(statements, request))

    def test_missing_negative_condition_and_if_exists_are_denied(self):
        for operator in ("StringNotEquals", "StringNotEqualsIfExists", "ArnNotLikeIfExists"):
            with self.subTest(operator=operator):
                self.assertTrue(condition_value(operator, None, "true"))
        self.assertFalse(condition_value("StringEquals", None, "true"))
        self.assertTrue(condition_value("StringEqualsIfExists", None, "true"))

    def test_not_resource_and_not_action_are_both_respected(self):
        statements = [{"Effect": "Allow", "Action": "*", "Resource": "*"}, {
            "Effect": "Deny", "NotAction": "rds:Describe*", "NotResource": "arn:gate:*"}]
        self.assertEqual("Deny", decision(statements, ("rds:DeleteDBInstance", "arn:foreign:db", {})))
        self.assertEqual("Allow", decision(statements, ("rds:DeleteDBInstance", "arn:gate:db", {})))
        self.assertEqual("Allow", decision(statements, ("rds:DescribeDBInstances", "*", {})))

    def test_unknown_operator_fails_closed(self):
        with self.assertRaises(ValueError):
            condition_value("Unsupported", "value", "value")

    def test_null_checks_and_multiple_expected_values(self):
        self.assertTrue(condition_value("Null", None, "true"))
        self.assertFalse(condition_value("Null", "present", "true"))
        self.assertTrue(condition_value("StringEquals", "b", ["a", "b"]))
        self.assertFalse(condition_value("StringNotEquals", "b", ["a", "b"]))


if __name__ == "__main__":
    unittest.main()

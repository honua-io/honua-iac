"""Optional features are excluded only when template properties disprove them."""
import unittest

from features import project_resource
from scope import activates, excluded, property_present


class FeatureTests(unittest.TestCase):
    def test_optional_handlers_follow_template_features_after_projection(self):
        cases = [
            ("ApplicationAutoScaling::ScalableTarget", "lambda:PutProvisionedConcurrencyConfig", "ServiceNamespace", "ecs", "lambda"),
            ("CloudTrail::Trail", "organizations:DescribeOrganization", "IsOrganizationTrail", False, True),
            ("EC2::EIP", "ec2:AcceptAddressTransfer", "TransferAddress", None, "192.0.2.1"),
            ("EC2::VPCGatewayAttachment", "ec2:AttachVpnGateway", "VpnGatewayId", None, {"Ref": "Gateway"}),
        ]
        for suffix, action, key, absent, present in cases:
            with self.subTest(action=action):
                resource = {"Type": "AWS::" + suffix, "Properties": {key: absent}}
                self.assertIsNotNone(excluded(resource, action))
                self.assertIsNotNone(excluded(project_resource(resource), action))
                resource["Properties"][key] = present
                self.assertIsNone(excluded(resource, action))
                self.assertIsNone(excluded(project_resource(resource), action))

    def test_intrinsics_and_conditional_branches_remain_required(self):
        for value in ({"Ref": "Unknown"}, {"Fn::Sub": "unknown"}, {
            "Fn::If": ["Condition", {"Ref": "AWS::NoValue"}, {"S3Bucket": "bucket"}]}):
            with self.subTest(value=value):
                self.assertTrue(property_present(value, ["S3Bucket"]))
        self.assertFalse(property_present({"Ref": "AWS::NoValue"}, []))

    def test_equality_inside_unknown_or_conditional_parent_is_required(self):
        for properties in ({"Config": {"Ref": "Unknown"}}, {"Config": {"Fn::If": ["C", {"Mode": "s3"}, {"Mode": "logs"}]}}):
            self.assertTrue(activates(properties, "Config.Mode=s3"))
        self.assertFalse(activates({"Config": {"Ref": "AWS::NoValue"}}, "Config.Mode=s3"))

    def test_new_s3_code_feature_reactivates_permission(self):
        resource = {"Type": "AWS::Lambda::Function", "Properties": {"Code": {"ZipFile": "private code"}}}
        self.assertIsNotNone(excluded(resource, "s3:GetObject"))
        resource["Properties"]["Code"] = {"S3Bucket": {"Ref": "ArtifactBucket"}}
        self.assertIsNone(excluded(resource, "s3:GetObject"))

    def test_projection_omits_private_code_and_identifiers(self):
        resource = {"Type": "AWS::Lambda::Function", "Properties": {
            "FunctionName": "private-name", "Code": {"ZipFile": "private code"},
            "Layers": ["arn:aws:lambda:private-region:private-account:layer:private-name"]}}
        result = project_resource(resource)
        self.assertNotIn("private", str(result))
        self.assertNotIn("ZipFile", str(result))
        self.assertIsNone(excluded(result, "lambda:GetLayerVersion"))

    def test_destination_service_survives_substitution_and_projection(self):
        for destination, required in [
            ({"Fn::Sub": "arn:${AWS::Partition}:logs:${AWS::Region}:${AWS::AccountId}:log-group:private"}, False),
            ({"Fn::Sub": ["arn:${Partition}:s3:::${Bucket}", {"Bucket": "private"}]}, True),
            ({"Fn::Sub": "arn:aws:${Service}:region:account:private"}, True),
        ]:
            resource = {"Type": "AWS::WAFv2::LoggingConfiguration", "Properties": {
                "LogDestinationConfigs": [destination]}}
            for candidate in (resource, project_resource(resource)):
                with self.subTest(destination=destination, projected=candidate is not resource):
                    self.assertEqual(required, excluded(candidate, "s3:GetBucketPolicy") is None)
            self.assertNotIn("private", str(project_resource(resource)))

    def test_log_delivery_permissions_require_data_protection_policy(self):
        resource = {"Type": "AWS::Logs::LogGroup", "Properties": {}}
        for action in ("s3:REST.PUT.OBJECT", "firehose:TagDeliveryStream"):
            self.assertIsNotNone(excluded(resource, action))
            self.assertIsNotNone(excluded(project_resource(resource), action))
        resource["Properties"]["DataProtectionPolicy"] = {"Ref": "Unknown"}
        for action in ("s3:REST.PUT.OBJECT", "firehose:TagDeliveryStream"):
            self.assertIsNone(excluded(resource, action))
            self.assertIsNone(excluded(project_resource(resource), action))

    def test_unknown_actions_have_no_exception(self):
        self.assertIsNone(excluded({"Type": "AWS::Lambda::Function"}, "invented:Action"))

    def test_literal_destination_and_unknown_destination_differ(self):
        self.assertFalse(activates({"LogDestinationConfigs": ["arn:aws:logs:synthetic"]}, "LogDestinationConfigs~s3"))
        self.assertTrue(activates({"LogDestinationConfigs": [{"Ref": "Unknown"}]}, "LogDestinationConfigs~s3"))


if __name__ == "__main__":
    unittest.main()

"""Custom resources use their execution role, never the CloudFormation role."""
import unittest

from audit import audit
from features import project_snapshot
from runtime import inline_actions


class RuntimeTests(unittest.TestCase):
    def test_custom_role_calls_remain_unverified_under_cloudformation_allow_all(self):
        resources = {
            "Custom": {"Type": "Custom::Example", "Properties": {
                "ServiceToken": {"Fn::GetAtt": ["Handler", "Arn"]}}},
            "Handler": {"Type": "AWS::Lambda::Function", "Properties": {
                "Code": {"ZipFile": "import boto3\nclient=boto3.client('s3')\nclient.get_object(Bucket='private-name', Key='private-key')"}}},
        }
        snapshot = {"templates": [{"resources": resources}], "schemas": {
            "AWS::Lambda::Function": {"handlers": {}}}, "authorization": {
                "s3": {"Actions": [{"Name": "GetObject"}], "Resources": []}}}
        projected = project_snapshot(snapshot)
        self.assertNotIn("Custom::Example", str(projected))
        self.assertNotIn("private-name", str(projected))
        self.assertNotIn("boto3", str(projected))
        rows = audit(projected, [{"Effect": "Allow", "Action": "*", "Resource": "*"}])
        self.assertEqual([("s3:GetObject", "UnverifiedRuntimePolicy")],
                         [(row["action"], row["decision"]) for row in rows])

    def test_default_argument_clients_are_included(self):
        code = "import boto3\ndef handler(event, context, client=boto3.client('bedrock')):\n client.get_model_invocation_logging_configuration()"
        service = {"bedrock": {"Actions": [{"Name": "GetModelInvocationLoggingConfiguration"}]}}
        self.assertEqual(["bedrock:GetModelInvocationLoggingConfiguration"], inline_actions(code, service))

    def test_sdk_client_passed_to_helper_is_included(self):
        code = "import boto3\ndef configure(client, bucket):\n client.put_model_invocation_logging_configuration()\nconfigure(boto3.client('bedrock'), 'synthetic')"
        service = {"bedrock": {"Actions": [{"Name": "PutModelInvocationLoggingConfiguration"}]}}
        self.assertEqual(["bedrock:PutModelInvocationLoggingConfiguration"], inline_actions(code, service))

    def test_external_handler_stays_unmapped(self):
        snapshot = {"templates": [{"resources": {"Custom": {
            "Type": "Custom::External", "Properties": {"ServiceToken": {"Ref": "External"}}}}}],
            "schemas": {}, "authorization": {}}
        projected = project_snapshot(snapshot)
        self.assertEqual("UnmappedCustomHandler", audit(projected, [])[0]["decision"])

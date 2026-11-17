"""Coverage failures must stay visible even with an allow-all IAM policy."""
import unittest
from audit import audit, evaluate
from requests import resource_for
from actions import authorization_action


class CoverageTests(unittest.TestCase):
    def test_kms_alias_update_requires_both_current_and_new_key(self):
        service = {"Actions": [{"Name": "UpdateAlias", "Resources": [
            {"Name": "alias"}, {"Name": "key"}]}], "Resources": [
            {"Name": "alias", "ARNFormats": ["arn:aws:kms:${Region}:${Account}:alias/${AliasName}"]},
            {"Name": "key", "ARNFormats": ["arn:aws:kms:${Region}:${Account}:key/${KeyId}"]}]}
        spec = {"type": "AWS::KMS::Alias", "handler": "update", "action": "kms:UpdateAlias", "schema": {}}
        policy = [{"Effect": "Allow", "Action": "kms:UpdateAlias", "Resource": "arn:aws:kms:*:*:alias/*"}]
        requests, result = evaluate(spec, service, policy)
        self.assertEqual("ImplicitDeny", result)
        self.assertEqual(3, len(requests))
        self.assertNotEqual(requests[1][1], requests[2][1])

    def test_kms_alias_delete_also_requires_the_backing_key(self):
        service = {"Actions": [{"Name": "DeleteAlias", "Resources": [
            {"Name": "alias"}, {"Name": "key"}]}], "Resources": [
            {"Name": "alias", "ARNFormats": ["arn:aws:kms:${Region}:${Account}:alias/${AliasName}"]},
            {"Name": "key", "ARNFormats": ["arn:aws:kms:${Region}:${Account}:key/${KeyId}"]}]}
        spec = {"type": "AWS::KMS::Alias", "handler": "delete", "action": "kms:DeleteAlias", "schema": {}}
        policy = [{"Effect": "Allow", "Action": "kms:DeleteAlias", "Resource": "arn:aws:kms:*:*:alias/*"}]
        requests, result = evaluate(spec, service, policy)
        self.assertEqual("ImplicitDeny", result)
        self.assertEqual(2, len(requests))

    def test_distribution_creation_requires_create_and_tag_actions(self):
        service = {"Actions": [{"Name": name, "Resources": []}
                               for name in ["CreateDistribution", "TagResource"]]}
        spec = {"type": "AWS::CloudFront::Distribution", "handler": "create",
                "action": "cloudfront:CreateDistributionWithTags", "schema": {}}
        policy = [{"Effect": "Allow", "Action": "cloudfront:CreateDistribution", "Resource": "*"}]
        requests, result = evaluate(spec, service, policy)
        self.assertEqual("ImplicitDeny", result)
        self.assertEqual({"cloudfront:CreateDistribution", "cloudfront:TagResource"},
                         {request[0] for request in requests})

    def test_registry_api_names_are_normalized_to_iam_actions(self):
        self.assertEqual("s3:PutReplicationConfiguration", authorization_action("s3:PutBucketReplication"))
        self.assertEqual("s3:PutBucketCORS", authorization_action("s3:DeleteBucketCors"))
        self.assertEqual("s3:DeleteBucket", authorization_action("s3:DeleteBucket"))

    def test_each_resource_keeps_its_optional_features(self):
        resources = {
            "Inline": {"Type": "AWS::Lambda::Function", "Properties": {"Code": {"ZipFile": "code"}}},
            "Archive": {"Type": "AWS::Lambda::Function", "Properties": {"Code": {"S3Bucket": "bucket"}}},
        }
        snapshot = {"templates": [{"resources": resources}], "authorization": {"s3": {
            "Actions": [{"Name": "GetObject", "Resources": []}]}}, "schemas": {
            "AWS::Lambda::Function": {"handlers": {"create": ["s3:GetObject"]}}}}
        rows = audit(snapshot, [{"Effect": "Allow", "Action": "*", "Resource": "*"}])
        self.assertEqual({"Inline", "Archive"}, {row["resource"] for row in rows})
        self.assertEqual(["NotApplicable", "Allow"], [row["decision"] for row in rows])

    def test_custom_handler_is_not_silently_omitted(self):
        snapshot = {"templates": [{"resources": {"Custom": {"Type": "Custom::Unknown"}}}], "schemas": {}, "authorization": {}}
        rows = audit(snapshot, [{"Effect": "Allow", "Action": "*", "Resource": "*"}])
        self.assertEqual(1, len(rows))
        self.assertEqual("UnmappedCustomHandler", rows[0]["decision"])

    def test_ambiguous_resources_are_not_guessed(self):
        service = {"Actions": [{"Name": "Call", "Resources": [{"Name": "first"}, {"Name": "second"}]}],
                   "Resources": [{"Name": "first"}, {"Name": "second"}]}
        with self.assertRaises(ValueError):
            resource_for("AWS::Unknown::Thing", "unknown:Call", service)

    def test_bucket_object_reads_use_object_not_access_point(self):
        service = {"Actions": [{"Name": "GetObject", "Resources": [{"Name": "accesspointobject"}, {"Name": "object"}]}],
                   "Resources": [{"Name": "accesspointobject"}, {"Name": "object"}]}
        self.assertEqual("object", resource_for("AWS::Lambda::Function", "s3:GetObject", service)[1]["Name"])


if __name__ == "__main__":
    unittest.main()

"""Offline regression checks for the Service-to-NLB identity read."""

import io
import json
import runpy
import subprocess
import unittest
from pathlib import Path
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / "scripts/read-service-load-balancer.py"
ARN = (
    "arn:aws:elasticloadbalancing:us-east-1:123456789012:"
    "loadbalancer/net/honua-it/aaaaaaaaaaaaaaaa"
)
CERT = "arn:aws:acm:us-east-1:123456789012:certificate/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
DNS = "honua-it.elb.us-east-1.amazonaws.com"


class ReadServiceLoadBalancerTests(unittest.TestCase):
    def setUp(self):
        self.query = {
            "region": "us-east-1", "account_id": "123456789012", "partition": "aws",
            "cluster_name": "honua-it", "namespace": "honua",
            "service_name": "honua-public", "target_id": "honua-it",
            "controller": "legacy-service-controller", "hostname": DNS,
            "certificate_arn": CERT,
        }
        self.loads = [{
            "LoadBalancerArn": ARN, "DNSName": DNS, "Type": "network",
            "Scheme": "internet-facing", "State": {"Code": "active"},
            "CanonicalHostedZoneId": "ZELBEXAMPLE",
        }]
        self.tags = {
            "honua.io/target-id": "honua-it",
            "kubernetes.io/service-name": "honua/honua-public",
            "kubernetes.io/cluster/honua-it": "owned",
        }
        self.listeners = [{
            "LoadBalancerArn": ARN, "Port": 443, "Protocol": "TLS",
            "Certificates": [{"CertificateArn": CERT}],
        }]
        self.calls = []

    def execute(self):
        output = io.StringIO()

        def fake_run(command, **kwargs):
            self.calls.append((command, kwargs))
            self.assertEqual(kwargs["env"]["AWS_IGNORE_CONFIGURED_ENDPOINT_URLS"], "true")
            operation = command[2]
            if operation == "describe-load-balancers":
                response = {"LoadBalancers": self.loads}
            elif operation == "describe-tags":
                response = {"TagDescriptions": [{
                    "ResourceArn": ARN,
                    "Tags": [{"Key": key, "Value": value} for key, value in self.tags.items()],
                }]}
            elif operation == "describe-listeners":
                response = {"Listeners": self.listeners}
            else:
                self.fail(f"Unexpected AWS CLI operation: {operation}")
            return subprocess.CompletedProcess(command, 0, json.dumps(response), "")

        with patch("sys.stdin", io.StringIO(json.dumps(self.query))), \
             patch("sys.stdout", output), patch("subprocess.run", side_effect=fake_run):
            runpy.run_path(str(SCRIPT), run_name="__main__")
        return json.loads(output.getvalue())

    def test_legacy_service_identity_and_certificate(self):
        result = self.execute()
        self.assertEqual(result, {
            "arn": ARN, "dns_name": DNS,
            "canonical_hosted_zone_id": "ZELBEXAMPLE",
        })
        self.assertEqual(len(self.calls), 3)

    def test_controller_service_identity(self):
        self.query["controller"] = "aws-load-balancer-controller"
        self.tags = {
            "honua.io/target-id": "honua-it",
            "service.k8s.aws/stack": "honua/honua-public",
            "service.k8s.aws/resource": "LoadBalancer",
            "elbv2.k8s.aws/cluster": "honua-it",
        }
        self.assertEqual(self.execute()["arn"], ARN)

    def test_duplicate_hostname_refused(self):
        self.loads.append(dict(self.loads[0]))
        with self.assertRaises(SystemExit):
            self.execute()

    def test_substituted_target_tag_refused(self):
        self.tags["honua.io/target-id"] = "other"
        with self.assertRaises(SystemExit):
            self.execute()

    def test_wrong_tls_certificate_refused(self):
        self.listeners[0]["Certificates"] = []
        with self.assertRaises(SystemExit):
            self.execute()


if __name__ == "__main__":
    unittest.main()

"""Offline checks for the public Route53 zone read used by the A alias."""

import io
import json
import runpy
import subprocess
import unittest
from pathlib import Path
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / "scripts/read-public-hosted-zone.py"


class ReadPublicHostedZoneTests(unittest.TestCase):
    def setUp(self):
        self.response = {"HostedZone": {
            "Id": "/hostedzone/ZEXAMPLE",
            "Name": "example.com.",
            "Config": {"PrivateZone": False},
        }}

    def execute(self):
        output = io.StringIO()

        def fake_run(command, **kwargs):
            self.assertEqual(command[:5], [
                "aws", "route53", "get-hosted-zone", "--id", "ZEXAMPLE",
            ])
            self.assertEqual(kwargs["env"]["AWS_IGNORE_CONFIGURED_ENDPOINT_URLS"], "true")
            return subprocess.CompletedProcess(command, 0, json.dumps(self.response), "")

        with patch("sys.stdin", io.StringIO(json.dumps({
            "zone_id": "ZEXAMPLE", "region": "us-east-1",
        }))), patch("sys.stdout", output), patch("subprocess.run", side_effect=fake_run):
            runpy.run_path(str(SCRIPT), run_name="__main__")
        return json.loads(output.getvalue())

    def test_exact_public_zone_returned(self):
        self.assertEqual(self.execute(), {
            "zone_id": "ZEXAMPLE", "name": "example.com.",
        })

    def test_private_zone_refused(self):
        self.response["HostedZone"]["Config"]["PrivateZone"] = True
        with self.assertRaises(SystemExit):
            self.execute()

    def test_missing_visibility_refused(self):
        self.response["HostedZone"]["Config"] = {}
        with self.assertRaises(SystemExit):
            self.execute()

    def test_substituted_zone_id_refused(self):
        self.response["HostedZone"]["Id"] = "/hostedzone/ZOTHER"
        with self.assertRaises(SystemExit):
            self.execute()


if __name__ == "__main__":
    unittest.main()

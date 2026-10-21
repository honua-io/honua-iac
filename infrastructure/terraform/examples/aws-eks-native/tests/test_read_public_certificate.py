"""Offline checks for ACM certificate hostname validation."""

import io
import json
import runpy
import subprocess
import unittest
from pathlib import Path
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / "scripts/read-public-certificate.py"
ARN = "arn:aws:acm:us-east-1:123456789012:certificate/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"


class ReadPublicCertificateTests(unittest.TestCase):
    def setUp(self):
        self.certificate = {
            "CertificateArn": ARN,
            "Status": "ISSUED",
            "SubjectAlternativeNames": ["*.example.com"],
        }
        self.hostname = "gis.example.com"

    def execute(self):
        output = io.StringIO()

        def fake_run(command, **kwargs):
            self.assertEqual(command[:5], ["aws", "acm", "describe-certificate", "--certificate-arn", ARN])
            self.assertEqual(kwargs["env"]["AWS_IGNORE_CONFIGURED_ENDPOINT_URLS"], "true")
            return subprocess.CompletedProcess(command, 0, json.dumps({"Certificate": self.certificate}), "")

        with patch("sys.stdin", io.StringIO(json.dumps({
            "certificate_arn": ARN, "hostname": self.hostname, "region": "us-east-1",
        }))), patch("sys.stdout", output), patch("subprocess.run", side_effect=fake_run):
            runpy.run_path(str(SCRIPT), run_name="__main__")
        return json.loads(output.getvalue())

    def test_wildcard_covers_one_label(self):
        self.assertEqual(self.execute(), {"certificate_arn": ARN, "hostname": self.hostname})

    def test_exact_san_covers_hostname(self):
        self.certificate["SubjectAlternativeNames"] = [self.hostname]
        self.assertEqual(self.execute()["hostname"], self.hostname)

    def test_wildcard_does_not_cover_apex_or_two_labels(self):
        for hostname in ["example.com", "deep.gis.example.com"]:
            with self.subTest(hostname=hostname), self.assertRaises(SystemExit):
                self.hostname = hostname
                self.execute()

    def test_other_hostname_refused(self):
        self.certificate["SubjectAlternativeNames"] = ["other.example.com"]
        with self.assertRaises(SystemExit):
            self.execute()

    def test_unissued_certificate_refused(self):
        self.certificate["Status"] = "PENDING_VALIDATION"
        with self.assertRaises(SystemExit):
            self.execute()

    def test_substituted_arn_refused(self):
        self.certificate["CertificateArn"] = ARN.replace("aaaaaaaa", "bbbbbbbb")
        with self.assertRaises(SystemExit):
            self.execute()


if __name__ == "__main__":
    unittest.main()

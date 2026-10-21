#!/usr/bin/env python3
"""Require an issued ACM certificate that covers the exact public hostname."""

import json
import os
import re
import subprocess
import sys


def refuse(reason):
    raise SystemExit(f"Public certificate observation refused: {reason}")


def covers(pattern, hostname):
    pattern = pattern.lower().rstrip(".")
    if pattern == hostname:
        return True
    if pattern.startswith("*."):
        suffix = pattern[2:]
        prefix = hostname.removesuffix("." + suffix)
        return hostname.endswith("." + suffix) and prefix != hostname and bool(prefix) and "." not in prefix
    return False


query = json.load(sys.stdin)
certificate_arn = query["certificate_arn"]
hostname = query["hostname"]
if not re.fullmatch(r"[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?", hostname):
    refuse("invalid hostname")

environment = os.environ.copy()
environment.update({
    "AWS_IGNORE_CONFIGURED_ENDPOINT_URLS": "true",
    "AWS_CLI_AUTO_PROMPT": "off",
    "AWS_PAGER": "",
})
result = subprocess.run(
    [
        "aws", "acm", "describe-certificate", "--certificate-arn", certificate_arn,
        "--region", query["region"], "--output", "json", "--no-cli-pager",
    ],
    capture_output=True, text=True, timeout=30, check=False, env=environment,
)
if result.returncode != 0:
    refuse("AWS ACM read failed")
try:
    certificate = json.loads(result.stdout)["Certificate"]
except (json.JSONDecodeError, KeyError, TypeError):
    refuse("AWS ACM returned invalid certificate JSON")

if certificate.get("CertificateArn") != certificate_arn:
    refuse("the certificate ARN differs")
if certificate.get("Status") != "ISSUED":
    refuse("the certificate is not issued")
names = certificate.get("SubjectAlternativeNames")
if not isinstance(names, list) or not all(isinstance(name, str) for name in names):
    refuse("certificate subject alternative names are missing or invalid")
if not any(covers(name, hostname) for name in names):
    refuse("the certificate does not cover the public hostname")

json.dump({"certificate_arn": certificate_arn, "hostname": hostname}, sys.stdout)

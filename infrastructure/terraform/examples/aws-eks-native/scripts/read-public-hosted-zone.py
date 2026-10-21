#!/usr/bin/env python3
"""Read and verify one public Route53 hosted zone by its exact ID."""

import json
import os
import re
import subprocess
import sys


def refuse(reason):
    raise SystemExit(f"Public hosted zone observation refused: {reason}")


query = json.load(sys.stdin)
zone_id = query["zone_id"]
if not re.fullmatch(r"Z[A-Z0-9]+", zone_id):
    refuse("invalid hosted zone ID")

environment = os.environ.copy()
environment.update({
    "AWS_IGNORE_CONFIGURED_ENDPOINT_URLS": "true",
    "AWS_CLI_AUTO_PROMPT": "off",
    "AWS_PAGER": "",
})
result = subprocess.run(
    [
        "aws", "route53", "get-hosted-zone", "--id", zone_id,
        "--region", query["region"], "--output", "json", "--no-cli-pager",
    ],
    capture_output=True, text=True, timeout=30, check=False, env=environment,
)
if result.returncode != 0:
    refuse("AWS Route53 read failed")
try:
    hosted_zone = json.loads(result.stdout)["HostedZone"]
except (json.JSONDecodeError, KeyError, TypeError):
    refuse("AWS Route53 returned invalid hosted-zone JSON")

if hosted_zone.get("Id") != f"/hostedzone/{zone_id}":
    refuse("the hosted zone ID differs")
if hosted_zone.get("Config", {}).get("PrivateZone") is not False:
    refuse("the hosted zone is private or its visibility is unknown")
name = hosted_zone.get("Name")
if not isinstance(name, str) or not name.endswith(".") or len(name) < 2:
    refuse("the hosted zone name is missing or invalid")

json.dump({"zone_id": zone_id, "name": name}, sys.stdout)

#!/usr/bin/env python3
"""Read existing EKS add-on status without owning or changing the add-on."""

import json
import subprocess
import sys


query = json.load(sys.stdin)
command = [
    "aws",
    "eks",
    "describe-addon",
    "--region",
    query["region"],
    "--cluster-name",
    query["cluster_name"],
    "--addon-name",
    query["addon_name"],
    "--output",
    "json",
]
result = subprocess.run(command, capture_output=True, text=True, check=False)
if result.returncode != 0:
    raise SystemExit("Unable to read the selected EKS add-on")
addon = json.loads(result.stdout)["addon"]
json.dump({"status": addon["status"], "addon_arn": addon["addonArn"]}, sys.stdout)

#!/usr/bin/env python3
"""Read an existing EKS association without adopting or mutating its ownership."""

import json
import subprocess
import sys


query = json.load(sys.stdin)
command = [
    "aws",
    "eks",
    "describe-pod-identity-association",
    "--region",
    query["region"],
    "--cluster-name",
    query["cluster_name"],
    "--association-id",
    query["association_id"],
    "--output",
    "json",
]
result = subprocess.run(command, capture_output=True, text=True, check=False)
if result.returncode != 0:
    raise SystemExit("Unable to read the selected EKS Pod Identity association")
association = json.loads(result.stdout)["association"]
json.dump(
    {
        "association_arn": association["associationArn"],
        "association_id": association["associationId"],
        "namespace": association["namespace"],
        "service_account": association["serviceAccount"],
        "role_arn": association["roleArn"],
    },
    sys.stdout,
)

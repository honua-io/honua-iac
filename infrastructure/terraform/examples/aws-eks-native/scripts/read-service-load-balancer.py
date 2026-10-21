#!/usr/bin/env python3
"""Read one controller-owned, tagged NLB behind a Kubernetes Service."""

import json
import os
import subprocess
import sys


def refuse(reason):
    raise SystemExit(f"Service load balancer observation refused: {reason}")


query = json.load(sys.stdin)
region = query["region"]


def aws(*args):
    command = [
        "aws", "elbv2", *args, "--region", region, "--output", "json",
        "--no-cli-pager",
    ]
    environment = os.environ.copy()
    environment.update({
        "AWS_IGNORE_CONFIGURED_ENDPOINT_URLS": "true",
        "AWS_CLI_AUTO_PROMPT": "off",
        "AWS_PAGER": "",
    })
    result = subprocess.run(
        command, capture_output=True, text=True, timeout=30, check=False,
        env=environment,
    )
    if result.returncode != 0:
        refuse("AWS ELBv2 read failed")
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError:
        refuse("AWS ELBv2 returned invalid JSON")


hostname = query["hostname"].rstrip(".").lower()
loads = aws("describe-load-balancers").get("LoadBalancers", [])
matches = [lb for lb in loads if lb.get("DNSName", "").rstrip(".").lower() == hostname]
if len(matches) != 1:
    refuse("the Service hostname did not identify exactly one load balancer")
load = matches[0]
arn = load.get("LoadBalancerArn", "")
expected_arn = (
    f"arn:{query['partition']}:elasticloadbalancing:{region}:"
    f"{query['account_id']}:loadbalancer/net/"
)
if (not arn.startswith(expected_arn) or load.get("Type") != "network"
        or load.get("Scheme") != "internet-facing"
        or load.get("State", {}).get("Code") != "active"
        or not load.get("CanonicalHostedZoneId")):
    refuse("the selected load balancer is not an active public NLB in the selected account")

tag_descriptions = aws("describe-tags", "--resource-arns", arn).get("TagDescriptions", [])
if len(tag_descriptions) != 1 or tag_descriptions[0].get("ResourceArn") != arn:
    refuse("the load balancer tags are unavailable")
tags = {tag["Key"]: tag["Value"] for tag in tag_descriptions[0].get("Tags", [])}
service = f"{query['namespace']}/{query['service_name']}"
if tags.get("honua.io/target-id") != query["target_id"]:
    refuse("the load balancer target tag differs")
if query["controller"] == "legacy-service-controller":
    if (tags.get("kubernetes.io/service-name") != service or
            tags.get(f"kubernetes.io/cluster/{query['cluster_name']}") not in ("owned", "shared")):
        refuse("legacy Service/cluster tags differ")
elif query["controller"] == "aws-load-balancer-controller":
    if (tags.get("service.k8s.aws/stack") != service or
            tags.get("service.k8s.aws/resource") != "LoadBalancer" or
            tags.get("elbv2.k8s.aws/cluster") != query["cluster_name"]):
        refuse("AWS Load Balancer Controller Service/cluster tags differ")
else:
    refuse("unsupported Service controller")

listeners = aws("describe-listeners", "--load-balancer-arn", arn).get("Listeners", [])
selected = [listener for listener in listeners
            if listener.get("LoadBalancerArn") == arn and listener.get("Port") == 443
            and listener.get("Protocol") == "TLS"]
if len(selected) != 1 or query["certificate_arn"] not in {
        certificate.get("CertificateArn")
        for certificate in selected[0].get("Certificates", [])
}:
    refuse("the selected NLB lacks the pinned TLS listener certificate")

json.dump({
    "arn": arn,
    "dns_name": load["DNSName"],
    "canonical_hosted_zone_id": load["CanonicalHostedZoneId"],
}, sys.stdout)

#!/usr/bin/env python3
"""Retire a stranded, UNTAGGED e2e-cloud-aws Lambda release cell whose Terraform
state artifact has expired.

THIS IS THE LAST RESORT. The preferred path is the stateful one:
honua-release `cloud-cell-retirement.yml` + `e2e/retire_cloud_cell.py` with
`serverless_cell_retirement.py`, which restores the run's sealed Terraform state
and destroys exactly what that state owns. This tool exists only for the case
that path cannot work: the run's `cloud-cell-handoff-*` / `cloud-cell-state-*`
artifacts have passed their 1-day retention and are gone. See
docs/devops/terraform-validation.md ("Untagged release-cell retirement").

Why it cannot reuse `sweep-orphaned-validation-infra.sh`: that sweeper is
tag-driven (Owner=terraform-validation + ValidationRunId) and is blind to
untagged resources by construction. Release cells carry only Name and
ManagedBy=terraform. That blindness is a safety property of the sweeper and is
deliberately NOT weakened; this tool is a separate, narrower, fail-closed path.

SAFETY. Every rule below runs before ANY mutating call and raises
RetirementRefused (exit 2) rather than skipping:

  * The run id is a `completed` honua-release e2e-cloud-aws run on the expected
    branch, completed longer than --grace-hours ago.
  * The run's handoff/state artifacts are really absent (expired or never
    uploaded). A live artifact means the stateful path is available: refuse.
  * Exactly one VPC is named `honua{n|r}awsse<run6>-it-vpc` with
    ManagedBy=terraform. <run6> is only the first six digits of the run id, so
    it is NOT a unique key by itself; every creation timestamp we can read
    (NAT gateway, RDS instance, ElastiCache) must also fall inside the run's
    own [created_at, completed_at + slack] window, and at least one must exist.
  * A candidate is either inside that VPC, or its name/identifier begins with
    the exact cell prefix `honua{n|r}awsse<run6>-it-`, or it is one of the exact
    DNS names (or an ACM `_<hex>.` validation record under one of them).
  * No candidate name may begin with a standing prefix (honua-cert-, honua-demo-).
  * Anything unexpected inside the VPC (EC2 instances, load balancers, foreign
    network interfaces, peering, VPN, non-default NACLs, foreign RDS/Lambda/
    cache, routes to peers) REFUSES the whole retirement.
  * Resource types the module can create but this tool cannot safely delete
    (Batch, ECR, CodeArtifact, Location, RDS Proxy, S3) REFUSE when found under
    the prefix rather than being guessed at.
  * RDS deletion protection REFUSES unless --disable-rds-deletion-protection.
  * Dry run is the default; --apply is required to delete.
  * After deleting, everything is enumerated again; any leftover is a failure.
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import time
from datetime import datetime, timedelta, timezone

SCHEMA = "honua.release-cell-untagged-retirement/v1"
RELEASE_REPO = "honua-io/honua-release"
WORKFLOW_PATH = ".github/workflows/e2e-cloud-aws.yml"
DEFAULT_BRANCH = "trunk"
DEFAULT_ZONE_ID = "Z089181827C9GKIKHXUTT"
ZONE_NAME = "demo.honua.io."
DNS_SUFFIX = "cert.demo.honua.io"
ARTIFACT_PREFIXES = ("cloud-cell-handoff-", "cloud-cell-state-")
STANDING_PREFIXES = ("honua-cert-", "honua-demo-")
RUN_SLACK_BEFORE = timedelta(minutes=5)
RUN_SLACK_AFTER = timedelta(hours=1)

# Interface/gateway endpoints the aws-serverless module can create in its VPC.
ENDPOINT_SUFFIXES = (
    ".secretsmanager", ".lambda", ".sts", ".monitoring", ".logs",
    ".codeartifact.api", ".codeartifact.repositories", ".s3",
)
# Requester-managed ENIs of services the cell uses.
ENI_DESCRIPTION_PREFIXES = (
    "RDSNetworkInterface", "Interface for NAT Gateway", "AWS Lambda VPC ENI",
    "ElastiCache ", "RDS Proxy", "VPC Endpoint Interface",
)
ENI_INTERFACE_TYPES = {"nat_gateway", "lambda", "vpc_endpoint"}

# Deletion order; each entry has a Deleter method of the same name.
ORDER = [
    "route53_record", "scheduler_schedule", "scheduler_group", "event_rule",
    "apigw_mapping", "apigw_domain", "apigw_api", "acm_certificate",
    "lambda_function", "rds_instance", "elasticache_group",
    "rds_subnet_group", "rds_parameter_group", "elasticache_subnet_group",
    "nat_gateway", "vpc_endpoint", "eip", "secret", "log_group", "sns_topic",
    "cloudwatch_alarm", "cloudwatch_dashboard", "iam_role", "iam_policy",
    "security_group", "route_table", "subnet", "internet_gateway", "vpc",
]

RETRY_CODES = {
    "DependencyViolation", "InvalidNetworkInterface.InUse", "ResourceInUseException",
    "InvalidDBInstanceState", "InvalidDBInstanceStateFault", "InvalidDBSubnetGroupStateFault",
    "InvalidDBParameterGroupState", "InvalidCacheSubnetGroupStateFault",
    "InvalidReplicationGroupState", "Throttling", "ThrottlingException", "RequestLimitExceeded",
    "TooManyRequestsException", "ConcurrentModificationException", "PriorRequestNotComplete",
    "InvalidChangeBatch.Retry", "IncorrectState", "DeleteConflict", "ServiceFailure",
}


class RetirementRefused(ValueError):
    """A safety rule failed. Nothing was (or will be) deleted."""


def utcnow():
    return datetime.now(timezone.utc)


def parse_time(value):
    if isinstance(value, datetime):
        return value if value.tzinfo else value.replace(tzinfo=timezone.utc)
    return datetime.fromisoformat(str(value).replace("Z", "+00:00"))


def iso(value):
    return parse_time(value).strftime("%Y-%m-%dT%H:%M:%SZ")


def error_code(error):
    response = getattr(error, "response", None) or {}
    return (response.get("Error") or {}).get("Code", "")


def is_gone(error):
    code = error_code(error)
    return "NotFound" in code or code in ("NoSuchEntity", "NoSuchEntityException", "ResourceNotFoundException")


class Cell:
    """Identity of one cell, derived only from run id + redis mode."""

    def __init__(self, run_id, redis, account_id, region, zone_id=DEFAULT_ZONE_ID):
        if not re.fullmatch(r"[1-9][0-9]{7,}", run_id or ""):
            raise RetirementRefused("run id must be a numeric GitHub run id")
        if redis not in ("off", "on"):
            raise RetirementRefused("redis must be off or on")
        if not re.fullmatch(r"[0-9]{12}", account_id or ""):
            raise RetirementRefused("account id must be 12 digits")
        if not re.fullmatch(r"[a-z]{2}-[a-z]+-[0-9]", region or ""):
            raise RetirementRefused("invalid region")
        self.run_id, self.redis, self.account_id, self.region = run_id, redis, account_id, region
        self.zone_id = zone_id
        self.cell = f"aws-serverless/redis-{redis}"
        self.prefix = f"honua{'r' if redis == 'on' else 'n'}awsse{run_id[:6]}-it"
        self.vpc_name = f"{self.prefix}-vpc"
        self.dns_name = f"{run_id}-aws-serverless-redis-{redis}.{DNS_SUFFIX}"
        self._validation = re.compile(r"^_[0-9a-f]+\." + re.escape(self.dns_name) + r"\.?$")

    def owns_name(self, name):
        """Exact-prefix ownership: `<prefix>-...` (or `<prefix>/...` for secrets)."""
        return isinstance(name, str) and (name.startswith(self.prefix + "-") or name.startswith(self.prefix + "/"))

    def owns_dns(self, name, record_type):
        if name.rstrip(".") == self.dns_name:
            return True
        return record_type == "CNAME" and bool(self._validation.match(name))


def refuse_standing(name):
    if any(str(name).startswith(p) for p in STANDING_PREFIXES):
        raise RetirementRefused(f"standing resource name is never eligible: {name}")


def claim(cell, name):
    """True only if name carries the exact cell prefix. A standing name is never
    a candidate (the account is full of them; they are simply not ours)."""
    return cell.owns_name(name) and not any(str(name).startswith(p) for p in STANDING_PREFIXES)


def assert_plan_clean(resources):
    """Defence in depth: no planned item may ever be a standing resource."""
    for items in resources.values():
        for item in items:
            for key in ("id", "name"):
                refuse_standing(str(item.get(key, "")).rsplit(":", 1)[-1].rsplit("/", 1)[-1])


# ---------------------------------------------------------------------------
# Run verification (GitHub)
# ---------------------------------------------------------------------------

def gh_api(path, run=subprocess.run):
    result = run(["gh", "api", path], text=True, capture_output=True, check=False)
    if result.returncode:
        raise RetirementRefused(f"cannot verify with GitHub ({path}): {result.stderr.strip()[:200]}")
    try:
        return json.loads(result.stdout)
    except ValueError as error:
        raise RetirementRefused(f"GitHub returned non-JSON for {path}") from error


def verify_run(cell, *, grace_hours, now, gh=gh_api, repo=RELEASE_REPO, branch=DEFAULT_BRANCH):
    run = gh(f"repos/{repo}/actions/runs/{cell.run_id}")
    if str(run.get("id")) != cell.run_id:
        raise RetirementRefused("GitHub returned a different run than requested")
    if run.get("status") != "completed" or not run.get("conclusion"):
        raise RetirementRefused(f"run is not completed (status={run.get('status')}); a live run owns its cell")
    if not str(run.get("path", "")).startswith(WORKFLOW_PATH):
        raise RetirementRefused(f"run is not an e2e-cloud-aws run (path={run.get('path')})")
    if run.get("head_branch") != branch:
        raise RetirementRefused(f"run head_branch {run.get('head_branch')!r} is not {branch!r}")
    try:
        created, completed = parse_time(run["created_at"]), parse_time(run["updated_at"])
    except (KeyError, ValueError) as error:
        raise RetirementRefused("run has no usable created_at/updated_at") from error
    if now - completed < timedelta(hours=grace_hours):
        raise RetirementRefused(f"grace window not elapsed: run completed {iso(completed)}, need {grace_hours}h")
    listing = gh(f"repos/{repo}/actions/runs/{cell.run_id}/artifacts?per_page=100")
    artifacts = listing.get("artifacts")
    if not isinstance(artifacts, list) or listing.get("total_count") != len(artifacts):
        raise RetirementRefused("artifact listing is missing or paginated; cannot prove the artifacts are absent")
    cell_artifacts = [a for a in artifacts if str(a.get("name", "")).startswith(ARTIFACT_PREFIXES)]
    live = [a.get("name") for a in cell_artifacts if not a.get("expired")]
    if live:
        raise RetirementRefused(f"handoff/state artifact still available ({live}); use the stateful retirement path")
    return {"status": run["status"], "conclusion": run["conclusion"], "path": run["path"],
            "headBranch": run["head_branch"], "createdAt": iso(created), "completedAt": iso(completed),
            "expiredArtifacts": sorted(a["name"] for a in cell_artifacts)}


# ---------------------------------------------------------------------------
# Enumeration (read-only)
# ---------------------------------------------------------------------------

def pages(client, operation, key, **kwargs):
    for page in client.get_paginator(operation).paginate(**kwargs):
        yield from page.get(key, [])


def api_pages(call, key, **kwargs):
    """apigatewayv2 has no paginators; follow NextToken by hand."""
    token = None
    while True:
        extra = {"NextToken": token} if token else {}
        page = call(**kwargs, **extra)
        yield from page.get(key, [])
        token = page.get("NextToken")
        if not token:
            return


def vpc_filter(vpc_id, name="vpc-id"):
    return [{"Name": name, "Values": [vpc_id]}]


def tag(resource, key):
    return next((t.get("Value") for t in resource.get("Tags", []) if t.get("Key") == key), None)


def enumerate_cell(aws, cell, *, strict=True, disable_rds_protection=False):
    """Read-only inventory. In strict mode any unexpected finding raises.

    Returns {"vpcId", "resources": {type: [item, ...]}, "created": [datetime],
    "problems": [...], "unsupported": {...}}. Non-strict mode (post-delete
    verification) reports problems and tolerates a missing VPC.
    """
    ec2 = aws.client("ec2")
    problems = []
    res = {kind: [] for kind in ORDER}
    created = []

    def problem(message):
        problems.append(message)
        if strict:
            raise RetirementRefused(message)

    vpcs = ec2.describe_vpcs(Filters=[{"Name": "tag:Name", "Values": [cell.vpc_name]}])["Vpcs"]
    vpc_id = None
    if len(vpcs) > 1 or (strict and not vpcs):
        raise RetirementRefused(f"expected exactly one VPC named {cell.vpc_name}, found {len(vpcs)}")
    if vpcs:
        vpc = vpcs[0]
        vpc_id = vpc["VpcId"]
        if vpc.get("IsDefault") or tag(vpc, "ManagedBy") != "terraform":
            raise RetirementRefused(f"VPC {vpc_id} is default or lacks ManagedBy=terraform")
        res["vpc"].append({"id": vpc_id})
        _enumerate_vpc(aws, cell, ec2, vpc_id, res, created, problem)
    _enumerate_regional(aws, cell, res, created, problem, vpc_id, disable_rds_protection)
    _enumerate_dns(aws, cell, res, problem)
    unsupported = _enumerate_unsupported(aws, cell)
    for kind, names in unsupported.items():
        problem(f"unsupported resource type under the cell prefix ({kind}: {names}); remove by hand or extend this tool")
    return {"vpcId": vpc_id, "resources": res, "created": created, "problems": problems, "unsupported": unsupported}


def _enumerate_vpc(aws, cell, ec2, vpc_id, res, created, problem):
    f = vpc_filter(vpc_id)
    for subnet in pages(ec2, "describe_subnets", "Subnets", Filters=f):
        res["subnet"].append({"id": subnet["SubnetId"]})
    igws = list(pages(ec2, "describe_internet_gateways", "InternetGateways", Filters=vpc_filter(vpc_id, "attachment.vpc-id")))
    if len(igws) > 1:
        problem(f"more than one internet gateway attached to {vpc_id}")
    for igw in igws:
        res["internet_gateway"].append({"id": igw["InternetGatewayId"]})
    for rt in pages(ec2, "describe_route_tables", "RouteTables", Filters=f):
        for route in rt.get("Routes", []):
            for peer in ("VpcPeeringConnectionId", "TransitGatewayId", "CarrierGatewayId", "LocalGatewayId", "CoreNetworkArn"):
                if route.get(peer):
                    problem(f"route table {rt['RouteTableId']} routes to a foreign {peer}")
        if not any(a.get("Main") for a in rt.get("Associations", [])):
            res["route_table"].append({"id": rt["RouteTableId"],
                                       "associations": [a["RouteTableAssociationId"] for a in rt.get("Associations", [])]})
    allocations = set()
    for nat in pages(ec2, "describe_nat_gateways", "NatGateways", Filter=f):
        if nat.get("State") == "deleted":
            continue
        res["nat_gateway"].append({"id": nat["NatGatewayId"]})
        created.append(parse_time(nat["CreateTime"]))
        allocations.update(a["AllocationId"] for a in nat.get("NatGatewayAddresses", []) if a.get("AllocationId"))
    # Only EIPs allocated to this cell's NAT gateway are ever released. An EIP on
    # an RDS ENI is released by AWS when the instance goes; it is verified gone
    # by the re-enumeration, never released by us.
    for allocation in sorted(allocations):
        res["eip"].append({"id": allocation})
    for endpoint in pages(ec2, "describe_vpc_endpoints", "VpcEndpoints", Filters=f):
        if endpoint.get("State") in ("deleted", "deleting"):
            continue
        service = endpoint.get("ServiceName", "")
        if not any(service.endswith(s) for s in ENDPOINT_SUFFIXES):
            problem(f"unexpected VPC endpoint {endpoint['VpcEndpointId']} ({service})")
        res["vpc_endpoint"].append({"id": endpoint["VpcEndpointId"]})
    for sg in pages(ec2, "describe_security_groups", "SecurityGroups", Filters=f):
        refuse_standing(sg["GroupName"])
        if sg["GroupName"] == "default":
            continue
        if not cell.owns_name(sg["GroupName"]):
            problem(f"security group {sg['GroupId']} ({sg['GroupName']}) in the VPC does not carry the cell prefix")
        res["security_group"].append({"id": sg["GroupId"]})
    for acl in pages(ec2, "describe_network_acls", "NetworkAcls", Filters=f):
        if not acl.get("IsDefault"):
            problem(f"non-default network ACL {acl['NetworkAclId']} in the VPC")
    for kind in ("requester-vpc-info.vpc-id", "accepter-vpc-info.vpc-id"):
        for peering in pages(ec2, "describe_vpc_peering_connections", "VpcPeeringConnections", Filters=vpc_filter(vpc_id, kind)):
            if (peering.get("Status") or {}).get("Code") not in ("deleted", "rejected", "failed", "expired"):
                problem(f"VPC peering connection {peering['VpcPeeringConnectionId']} touches the VPC")
    for gateway in ec2.describe_vpn_gateways(Filters=vpc_filter(vpc_id, "attachment.vpc-id")).get("VpnGateways", []):
        if gateway.get("State") != "deleted":
            problem(f"VPN gateway {gateway['VpnGatewayId']} attached to the VPC")
    for reservation in pages(ec2, "describe_instances", "Reservations", Filters=f):
        for instance in reservation.get("Instances", []):
            if (instance.get("State") or {}).get("Name") != "terminated":
                problem(f"EC2 instance {instance['InstanceId']} is inside the VPC")
    for lb in pages(aws.client("elbv2"), "describe_load_balancers", "LoadBalancers"):
        if lb.get("VpcId") == vpc_id:
            problem(f"load balancer {lb['LoadBalancerName']} is inside the VPC")
    for eni in pages(ec2, "describe_network_interfaces", "NetworkInterfaces", Filters=f):
        description = eni.get("Description", "")
        managed = eni.get("InterfaceType") in ENI_INTERFACE_TYPES or description.startswith(ENI_DESCRIPTION_PREFIXES)
        if (eni.get("Attachment") or {}).get("InstanceId") or not managed:
            problem(f"unexpected network interface {eni['NetworkInterfaceId']} ({description!r}) in the VPC")


def _enumerate_regional(aws, cell, res, created, problem, vpc_id, disable_rds_protection):
    lam = aws.client("lambda")
    for fn in pages(lam, "list_functions", "Functions"):
        name = fn["FunctionName"]
        if claim(cell, name):
            res["lambda_function"].append({"id": name})
        elif vpc_id and (fn.get("VpcConfig") or {}).get("VpcId") == vpc_id:
            problem(f"foreign Lambda function {name} is attached to the cell VPC")
    rds = aws.client("rds")
    for db in pages(rds, "describe_db_instances", "DBInstances"):
        name = db["DBInstanceIdentifier"]
        in_vpc = bool(vpc_id) and (db.get("DBSubnetGroup") or {}).get("VpcId") == vpc_id
        if not claim(cell, name):
            if in_vpc:
                refuse_standing(name)
                problem(f"foreign RDS instance {name} is inside the cell VPC")
            continue
        if vpc_id is not None and not in_vpc:
            problem(f"RDS instance {name} carries the cell prefix but is not in the cell VPC")
        if db.get("ReadReplicaDBInstanceIdentifiers") or db.get("ReadReplicaSourceDBInstanceIdentifier"):
            problem(f"RDS instance {name} has read replicas or is one")
        if db.get("DeletionProtection") and not disable_rds_protection:
            problem(f"RDS instance {name} has deletion protection enabled; the plan must say --disable-rds-deletion-protection")
        if db.get("InstanceCreateTime"):
            created.append(parse_time(db["InstanceCreateTime"]))
        res["rds_instance"].append({"id": name, "deletionProtection": bool(db.get("DeletionProtection"))})
    for group in pages(rds, "describe_db_subnet_groups", "DBSubnetGroups"):
        name = group["DBSubnetGroupName"]
        if claim(cell, name):
            if vpc_id is not None and group.get("VpcId") != vpc_id:
                problem(f"DB subnet group {name} is outside the cell VPC")
            res["rds_subnet_group"].append({"id": name})
        elif vpc_id and group.get("VpcId") == vpc_id and name != "default":
            problem(f"foreign DB subnet group {name} is inside the cell VPC")
    for group in pages(rds, "describe_db_parameter_groups", "DBParameterGroups"):
        if claim(cell, group["DBParameterGroupName"]):
            res["rds_parameter_group"].append({"id": group["DBParameterGroupName"]})
    cache = aws.client("elasticache")
    for group in pages(cache, "describe_replication_groups", "ReplicationGroups"):
        if claim(cell, group["ReplicationGroupId"]):
            res["elasticache_group"].append({"id": group["ReplicationGroupId"]})
    for cluster in pages(cache, "describe_cache_clusters", "CacheClusters"):
        owner = cluster.get("ReplicationGroupId") or cluster["CacheClusterId"]
        if claim(cell, owner):
            if cluster.get("CacheClusterCreateTime"):
                created.append(parse_time(cluster["CacheClusterCreateTime"]))
        elif claim(cell, cluster.get("CacheSubnetGroupName") or ""):
            problem(f"foreign cache cluster {owner} uses a cell subnet group")
    for group in pages(cache, "describe_cache_subnet_groups", "CacheSubnetGroups"):
        name = group["CacheSubnetGroupName"]
        if claim(cell, name):
            if vpc_id is not None and group.get("VpcId") != vpc_id:
                problem(f"cache subnet group {name} is outside the cell VPC")
            res["elasticache_subnet_group"].append({"id": name})
    apigw = aws.client("apigatewayv2")
    for api in api_pages(apigw.get_apis, "Items"):
        if claim(cell, api["Name"]):
            res["apigw_api"].append({"id": api["ApiId"], "name": api["Name"]})
    for domain in api_pages(apigw.get_domain_names, "Items"):
        if domain["DomainName"] == cell.dns_name:
            res["apigw_domain"].append({"id": domain["DomainName"]})
            for mapping in api_pages(apigw.get_api_mappings, "Items", DomainName=domain["DomainName"]):
                res["apigw_mapping"].append({"id": mapping["ApiMappingId"], "domain": domain["DomainName"]})
    for cert in pages(aws.client("acm"), "list_certificates", "CertificateSummaryList"):
        if cert["DomainName"] == cell.dns_name:
            res["acm_certificate"].append({"id": cert["CertificateArn"]})
    for secret in pages(aws.client("secretsmanager"), "list_secrets", "SecretList"):
        if claim(cell, secret["Name"]):
            res["secret"].append({"id": secret["ARN"], "name": secret["Name"]})
    for group in pages(aws.client("logs"), "describe_log_groups", "logGroups", logGroupNamePrefix="/aws/"):
        segments = group["logGroupName"].strip("/").split("/")[2:]
        if any(s == cell.prefix or s.startswith(cell.prefix + "-") for s in segments):
            res["log_group"].append({"id": group["logGroupName"]})
    cw = aws.client("cloudwatch")
    for alarm in pages(cw, "describe_alarms", "MetricAlarms", AlarmNamePrefix=cell.prefix + "-"):
        if claim(cell, alarm["AlarmName"]):
            res["cloudwatch_alarm"].append({"id": alarm["AlarmName"]})
    for board in pages(cw, "list_dashboards", "DashboardEntries", DashboardNamePrefix=cell.prefix + "-"):
        if claim(cell, board["DashboardName"]):
            res["cloudwatch_dashboard"].append({"id": board["DashboardName"]})
    for topic in pages(aws.client("sns"), "list_topics", "Topics"):
        if claim(cell, topic["TopicArn"].rsplit(":", 1)[-1]):
            res["sns_topic"].append({"id": topic["TopicArn"]})
    for rule in pages(aws.client("events"), "list_rules", "Rules", NamePrefix=cell.prefix + "-"):
        if claim(cell, rule["Name"]) and rule.get("EventBusName", "default") == "default":
            res["event_rule"].append({"id": rule["Name"]})
    sched = aws.client("scheduler")
    for group in pages(sched, "list_schedule_groups", "ScheduleGroups", NamePrefix=cell.prefix + "-"):
        if claim(cell, group["Name"]):
            res["scheduler_group"].append({"id": group["Name"]})
            for schedule in pages(sched, "list_schedules", "Schedules", GroupName=group["Name"]):
                res["scheduler_schedule"].append({"id": schedule["Name"], "group": group["Name"]})
    iam = aws.client("iam")
    for role in pages(iam, "list_roles", "Roles"):
        if claim(cell, role["RoleName"]):
            res["iam_role"].append({"id": role["RoleName"]})
    for policy in pages(iam, "list_policies", "Policies", Scope="Local"):
        if claim(cell, policy["PolicyName"]):
            res["iam_policy"].append({"id": policy["Arn"], "name": policy["PolicyName"]})


def _enumerate_dns(aws, cell, res, problem):
    r53 = aws.client("route53")
    zone = r53.get_hosted_zone(Id=cell.zone_id)["HostedZone"]
    if zone["Name"] != ZONE_NAME:
        raise RetirementRefused(f"hosted zone {cell.zone_id} is {zone['Name']}, expected {ZONE_NAME}")
    for record in pages(r53, "list_resource_record_sets", "ResourceRecordSets", HostedZoneId=cell.zone_id):
        kind = record["Type"]
        if not cell.owns_dns(record["Name"], kind):
            continue
        if kind not in ("A", "AAAA", "CNAME"):
            problem(f"unexpected record type {kind} at {record['Name']}")
        res["route53_record"].append({"id": f"{record['Name']}|{kind}", "record": record})


def _enumerate_unsupported(aws, cell):
    """Module resources this tool will not delete. Found under the prefix => refuse."""
    batch = aws.client("batch")
    found = {
        "batch_compute_environment": [c["computeEnvironmentName"] for c in pages(batch, "describe_compute_environments", "computeEnvironments")],
        "batch_job_queue": [q["jobQueueName"] for q in pages(batch, "describe_job_queues", "jobQueues")],
        "batch_job_definition": sorted({d["jobDefinitionName"] for d in pages(batch, "describe_job_definitions", "jobDefinitions", status="ACTIVE")}),
        "ecr_repository": [r["repositoryName"] for r in pages(aws.client("ecr"), "describe_repositories", "repositories")],
        "codeartifact_domain": [d["name"] for d in pages(aws.client("codeartifact"), "list_domains", "domains")],
        "location_place_index": [i["IndexName"] for i in pages(aws.client("location"), "list_place_indexes", "Entries")],
        "rds_proxy": [p["DBProxyName"] for p in pages(aws.client("rds"), "describe_db_proxies", "DBProxies")],
        "s3_bucket": [b["Name"] for b in aws.client("s3").list_buckets().get("Buckets", [])],
    }
    found = {kind: [n for n in names if claim(cell, n)] for kind, names in found.items()}
    return {kind: names for kind, names in found.items() if names}


def check_binding(inventory, run):
    """Bind the six-digit prefix to this specific run by creation time."""
    created = inventory["created"]
    if not created:
        raise RetirementRefused("no NAT/RDS/cache creation time available; cannot bind the cell to the run")
    low = parse_time(run["createdAt"]) - RUN_SLACK_BEFORE
    high = parse_time(run["completedAt"]) + RUN_SLACK_AFTER
    outside = [iso(t) for t in created if not (low <= t <= high)]
    if outside:
        raise RetirementRefused(
            f"resources were created at {outside}, outside run window {run['createdAt']}..{run['completedAt']}; "
            "the six-digit prefix likely belongs to a different run")


def total(resources):
    return sum(len(items) for items in resources.values())


def flatten(resources):
    return {kind: [item["id"] for item in items] for kind, items in resources.items() if items}


# ---------------------------------------------------------------------------
# Deletion (only reached with --apply, after every refusal rule has passed)
# ---------------------------------------------------------------------------

class Deleter:
    def __init__(self, aws, cell, *, sleep=time.sleep, attempts=8, delay=15, eni_wait=2700,
                 disable_rds_protection=False):
        self.aws, self.cell, self.sleep = aws, cell, sleep
        self.attempts, self.delay, self.eni_wait = attempts, delay, eni_wait
        self.disable_rds_protection = disable_rds_protection

    def retry(self, fn):
        for attempt in range(self.attempts):
            try:
                return fn()
            except Exception as error:  # noqa: BLE001 - classified here
                if is_gone(error):
                    return None
                if error_code(error) not in RETRY_CODES or attempt == self.attempts - 1:
                    raise
                self.sleep(self.delay)

    def wait(self, client, waiter, **kwargs):
        client.get_waiter(waiter).wait(WaiterConfig={"Delay": 15, "MaxAttempts": 120}, **kwargs)

    def route53_record(self, item):
        self.retry(lambda: self.aws.client("route53").change_resource_record_sets(
            HostedZoneId=self.cell.zone_id,
            ChangeBatch={"Changes": [{"Action": "DELETE", "ResourceRecordSet": item["record"]}]}))

    def scheduler_schedule(self, item):
        self.retry(lambda: self.aws.client("scheduler").delete_schedule(Name=item["id"], GroupName=item["group"]))

    def scheduler_group(self, item):
        self.retry(lambda: self.aws.client("scheduler").delete_schedule_group(Name=item["id"]))

    def event_rule(self, item):
        events = self.aws.client("events")
        ids = [t["Id"] for t in pages(events, "list_targets_by_rule", "Targets", Rule=item["id"])]
        if ids:
            self.retry(lambda: events.remove_targets(Rule=item["id"], Ids=ids, Force=True))
        self.retry(lambda: events.delete_rule(Name=item["id"], Force=True))

    def apigw_mapping(self, item):
        self.retry(lambda: self.aws.client("apigatewayv2").delete_api_mapping(ApiMappingId=item["id"], DomainName=item["domain"]))

    def apigw_domain(self, item):
        self.retry(lambda: self.aws.client("apigatewayv2").delete_domain_name(DomainName=item["id"]))

    def apigw_api(self, item):
        self.retry(lambda: self.aws.client("apigatewayv2").delete_api(ApiId=item["id"]))

    def acm_certificate(self, item):
        self.retry(lambda: self.aws.client("acm").delete_certificate(CertificateArn=item["id"]))

    def lambda_function(self, item):
        # No Qualifier: removes the function with all versions, aliases,
        # permissions and event-invoke configs.
        self.retry(lambda: self.aws.client("lambda").delete_function(FunctionName=item["id"]))

    def rds_instance(self, item):
        rds = self.aws.client("rds")
        if item.get("deletionProtection"):
            if not self.disable_rds_protection:
                raise RetirementRefused(f"deletion protection on {item['id']} without --disable-rds-deletion-protection")
            self.retry(lambda: rds.modify_db_instance(DBInstanceIdentifier=item["id"], DeletionProtection=False, ApplyImmediately=True))
        self.retry(lambda: rds.delete_db_instance(DBInstanceIdentifier=item["id"], SkipFinalSnapshot=True, DeleteAutomatedBackups=True))
        self.wait(rds, "db_instance_deleted", DBInstanceIdentifier=item["id"])

    def elasticache_group(self, item):
        cache = self.aws.client("elasticache")
        self.retry(lambda: cache.delete_replication_group(ReplicationGroupId=item["id"], RetainPrimaryCluster=False))
        self.wait(cache, "replication_group_deleted", ReplicationGroupId=item["id"])

    def rds_subnet_group(self, item):
        self.retry(lambda: self.aws.client("rds").delete_db_subnet_group(DBSubnetGroupName=item["id"]))

    def rds_parameter_group(self, item):
        self.retry(lambda: self.aws.client("rds").delete_db_parameter_group(DBParameterGroupName=item["id"]))

    def elasticache_subnet_group(self, item):
        self.retry(lambda: self.aws.client("elasticache").delete_cache_subnet_group(CacheSubnetGroupName=item["id"]))

    def nat_gateway(self, item):
        ec2 = self.aws.client("ec2")
        self.retry(lambda: ec2.delete_nat_gateway(NatGatewayId=item["id"]))
        self.wait(ec2, "nat_gateway_deleted", NatGatewayIds=[item["id"]])

    def vpc_endpoint(self, item):
        self.retry(lambda: self.aws.client("ec2").delete_vpc_endpoints(VpcEndpointIds=[item["id"]]))

    def eip(self, item):
        # Only allocations that belonged to this cell's NAT gateway are planned,
        # and the NAT gateway is already deleted by now.
        self.retry(lambda: self.aws.client("ec2").release_address(AllocationId=item["id"]))

    def secret(self, item):
        if not self.cell.owns_name(item["name"]):
            raise RetirementRefused(f"refusing to force-delete a secret outside the cell prefix: {item['name']}")
        self.retry(lambda: self.aws.client("secretsmanager").delete_secret(SecretId=item["id"], ForceDeleteWithoutRecovery=True))

    def log_group(self, item):
        self.retry(lambda: self.aws.client("logs").delete_log_group(logGroupName=item["id"]))

    def sns_topic(self, item):
        self.retry(lambda: self.aws.client("sns").delete_topic(TopicArn=item["id"]))

    def cloudwatch_alarm(self, item):
        self.retry(lambda: self.aws.client("cloudwatch").delete_alarms(AlarmNames=[item["id"]]))

    def cloudwatch_dashboard(self, item):
        self.retry(lambda: self.aws.client("cloudwatch").delete_dashboards(DashboardNames=[item["id"]]))

    def iam_role(self, item):
        iam, name = self.aws.client("iam"), item["id"]
        for profile in pages(iam, "list_instance_profiles_for_role", "InstanceProfiles", RoleName=name):
            raise RetirementRefused(f"role {name} is in instance profile {profile['InstanceProfileName']}")
        for attached in pages(iam, "list_attached_role_policies", "AttachedPolicies", RoleName=name):
            self.retry(lambda a=attached: iam.detach_role_policy(RoleName=name, PolicyArn=a["PolicyArn"]))
        for inline in pages(iam, "list_role_policies", "PolicyNames", RoleName=name):
            self.retry(lambda p=inline: iam.delete_role_policy(RoleName=name, PolicyName=p))
        self.retry(lambda: iam.delete_role(RoleName=name))

    def iam_policy(self, item):
        iam, arn = self.aws.client("iam"), item["id"]
        for kind in ("Role", "User", "Group"):
            for entity in pages(iam, "list_entities_for_policy", f"Policy{kind}s", PolicyArn=arn):
                name = entity[f"{kind}Name"]
                if kind != "Role" or not self.cell.owns_name(name):
                    raise RetirementRefused(f"policy {item['name']} is attached to a foreign {kind.lower()} {name}")
                self.retry(lambda n=name: iam.detach_role_policy(RoleName=n, PolicyArn=arn))
        for version in pages(iam, "list_policy_versions", "Versions", PolicyArn=arn):
            if not version.get("IsDefaultVersion"):
                self.retry(lambda v=version: iam.delete_policy_version(PolicyArn=arn, VersionId=v["VersionId"]))
        self.retry(lambda: iam.delete_policy(PolicyArn=arn))

    def wait_for_enis(self, vpc_id):
        """Lambda/RDS/endpoint ENIs are requester-managed and drain on their own."""
        ec2, waited = self.aws.client("ec2"), 0
        while True:
            left = list(pages(ec2, "describe_network_interfaces", "NetworkInterfaces", Filters=vpc_filter(vpc_id)))
            if not left or waited >= self.eni_wait:
                return left
            self.sleep(30)
            waited += 30

    def revoke_security_group_rules(self, items):
        """Mutually referencing groups cannot be deleted in any order: revoke every rule first."""
        ec2 = self.aws.client("ec2")
        for item in items:
            for sg in ec2.describe_security_groups(GroupIds=[item["id"]])["SecurityGroups"]:
                if sg.get("IpPermissions"):
                    self.retry(lambda sg=sg: ec2.revoke_security_group_ingress(GroupId=sg["GroupId"], IpPermissions=sg["IpPermissions"]))
                if sg.get("IpPermissionsEgress"):
                    self.retry(lambda sg=sg: ec2.revoke_security_group_egress(GroupId=sg["GroupId"], IpPermissions=sg["IpPermissionsEgress"]))

    def security_group(self, item):
        self.retry(lambda: self.aws.client("ec2").delete_security_group(GroupId=item["id"]))

    def route_table(self, item):
        ec2 = self.aws.client("ec2")
        for association in item.get("associations", []):
            self.retry(lambda a=association: ec2.disassociate_route_table(AssociationId=a))
        self.retry(lambda: ec2.delete_route_table(RouteTableId=item["id"]))

    def subnet(self, item):
        self.retry(lambda: self.aws.client("ec2").delete_subnet(SubnetId=item["id"]))

    def internet_gateway(self, item):
        ec2 = self.aws.client("ec2")
        self.retry(lambda: ec2.detach_internet_gateway(InternetGatewayId=item["id"], VpcId=item["vpc"]))
        self.retry(lambda: ec2.delete_internet_gateway(InternetGatewayId=item["id"]))

    def vpc(self, item):
        self.retry(lambda: self.aws.client("ec2").delete_vpc(VpcId=item["id"]))


def delete_in_order(inventory, *, deleter, report):
    resources, vpc_id = inventory["resources"], inventory["vpcId"]
    for item in resources["internet_gateway"]:
        item["vpc"] = vpc_id
    for kind in ORDER:
        if kind == "security_group" and vpc_id:
            try:
                deleter.wait_for_enis(vpc_id)
                deleter.revoke_security_group_rules(resources[kind])
            except Exception as error:  # noqa: BLE001 - recorded; deletes below then fail visibly
                report["failed"].append({"type": "security_group_rules", "id": vpc_id, "error": str(error)[:200]})
        for item in resources[kind]:
            try:
                getattr(deleter, kind)(item)
                report["deleted"].append({"type": kind, "id": item["id"]})
            except Exception as error:  # noqa: BLE001 - recorded; the run is marked incomplete
                report["failed"].append({"type": kind, "id": item["id"],
                                         "error": f"{error_code(error) or type(error).__name__}: {str(error)[:200]}"})


# ---------------------------------------------------------------------------
# Orchestration
# ---------------------------------------------------------------------------

def print_plan(cell, run, inventory, mode):
    print(f"[PLAN] mode={mode} cell={cell.cell} prefix={cell.prefix} vpc={inventory['vpcId']} run={cell.run_id}")
    print(f"[PLAN] run completed {run['completedAt']} conclusion={run['conclusion']} expiredArtifacts={run['expiredArtifacts']}")
    for kind in ORDER:
        for item in inventory["resources"][kind]:
            print(f"[PLAN]   {kind}: {item['id']}")
    print(f"[PLAN] total resources: {total(inventory['resources'])}")


def write_summary(path, summary):
    if path:
        with open(path, "w", encoding="utf-8") as stream:
            json.dump(summary, stream, indent=2, sort_keys=True, default=str)
            stream.write("\n")


def retire(aws, cell, *, apply, grace_hours, summary_file, disable_rds_protection=False, gh=gh_api, now=None,
           sleep=time.sleep, deleter=None, branch=DEFAULT_BRANCH):
    now = now or utcnow()
    summary = {"schema": SCHEMA, "runId": cell.run_id, "cell": cell.cell, "prefix": cell.prefix,
               "accountId": cell.account_id, "region": cell.region, "mode": "apply" if apply else "dry-run",
               "status": "started", "resources": {}, "deleted": [], "failed": [], "remaining": {},
               "startedAt": iso(now), "finishedAt": None}
    try:
        identity = aws.client("sts").get_caller_identity()["Account"]
        if identity != cell.account_id:
            raise RetirementRefused(f"credentials belong to account {identity}, expected {cell.account_id}")
        if aws.region != cell.region:
            raise RetirementRefused("AWS clients are not bound to the requested region")
        run = verify_run(cell, grace_hours=grace_hours, now=now, gh=gh, branch=branch)
        summary["run"] = run
        inventory = enumerate_cell(aws, cell, strict=True, disable_rds_protection=disable_rds_protection)
        check_binding(inventory, run)
        assert_plan_clean(inventory["resources"])
        summary["resources"] = flatten(inventory["resources"])
        summary["status"] = "planned"
        print_plan(cell, run, inventory, summary["mode"])
        write_summary(summary_file, summary)
        if not apply:
            summary["status"] = "dry-run"
            return 0, summary
        deleter = deleter or Deleter(aws, cell, sleep=sleep, disable_rds_protection=disable_rds_protection)
        delete_in_order(inventory, deleter=deleter, report=summary)
        after = enumerate_cell(aws, cell, strict=False, disable_rds_protection=True)
        leftovers = flatten(after["resources"])
        if after["unsupported"]:
            leftovers["unsupported"] = after["unsupported"]
        if after["problems"]:
            leftovers["problems"] = after["problems"]
        summary["remaining"] = leftovers
        if summary["failed"] or leftovers:
            summary["status"] = "incomplete"
            print(f"[ERROR] cell not fully retired: failed={len(summary['failed'])} remaining={leftovers}", file=sys.stderr)
            return 1, summary
        summary["status"] = "retired"
        print("[INFO] cell retired; re-enumeration found nothing left")
        return 0, summary
    except RetirementRefused as error:
        summary.update(status="refused", refusal=str(error))
        print(f"[REFUSED] {error}", file=sys.stderr)
        return 2, summary
    finally:
        summary["finishedAt"] = iso(utcnow())
        write_summary(summary_file, summary)


class Aws:
    def __init__(self, region):
        import boto3  # lazy: unit tests need neither boto3 credentials nor network
        self.region = region
        self._session = boto3.session.Session(region_name=region)
        self._clients = {}

    def client(self, name):
        if name not in self._clients:
            self._clients[name] = self._session.client(name)
        return self._clients[name]


def parse_args(argv):
    parser = argparse.ArgumentParser(description="Retire a stranded untagged e2e-cloud-aws release cell (last resort).")
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--redis", required=True, choices=("off", "on"))
    parser.add_argument("--account-id", required=True)
    parser.add_argument("--region", required=True)
    parser.add_argument("--grace-hours", type=float, default=24)
    parser.add_argument("--hosted-zone-id", default=DEFAULT_ZONE_ID)
    parser.add_argument("--expected-branch", default=DEFAULT_BRANCH)
    parser.add_argument("--summary-file")
    parser.add_argument("--disable-rds-deletion-protection", action="store_true",
                        help="the plan turns off RDS deletion protection; otherwise a protected instance refuses")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--dry-run", action="store_true", help="enumerate and print the plan (default)")
    mode.add_argument("--apply", action="store_true", help="delete; without this nothing is modified")
    return parser.parse_args(argv)


def main(argv=None, aws=None, gh=gh_api):
    args = parse_args(argv)
    try:
        cell = Cell(args.run_id, args.redis, args.account_id, args.region, args.hosted_zone_id)
        if args.grace_hours < 1:
            raise RetirementRefused("--grace-hours must be at least 1")
    except RetirementRefused as error:
        print(f"[REFUSED] {error}", file=sys.stderr)
        return 2
    code, _ = retire(aws or Aws(args.region), cell, apply=args.apply, grace_hours=args.grace_hours,
                     summary_file=args.summary_file, disable_rds_protection=args.disable_rds_deletion_protection,
                     gh=gh, branch=args.expected_branch)
    return code


if __name__ == "__main__":
    sys.exit(main())

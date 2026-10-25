"""Refusal and ordering controls for the untagged release-cell retirement tool.

Everything runs against an in-memory fake of the boto3 clients: no network, no
credentials, no AWS calls.
"""
import copy
import json
from datetime import datetime, timedelta, timezone

import pytest

import retire_untagged_release_cell as tool
from retire_untagged_release_cell import Cell, RetirementRefused, retire

ACCOUNT = "585192672263"
REGION = "us-east-1"
RUN = "39911551529"
NOW = datetime(2026, 10, 25, 12, 0, tzinfo=timezone.utc)
CREATED = NOW - timedelta(days=2, hours=1)
COMPLETED = NOW - timedelta(days=2)
PREFIX = "honuanawsse399115-it"
DNS = f"{RUN}-aws-serverless-redis-off.cert.demo.honua.io"


class ClientError(Exception):
    def __init__(self, code):
        super().__init__(code)
        self.response = {"Error": {"Code": code}}


def run_doc(**overrides):
    doc = {"id": int(RUN), "status": "completed", "conclusion": "failure",
           "path": ".github/workflows/e2e-cloud-aws.yml", "head_branch": "trunk",
           "created_at": CREATED.isoformat(), "updated_at": COMPLETED.isoformat()}
    doc.update(overrides)
    return doc


def make_gh(run=None, artifacts=None):
    run = run or run_doc()
    artifacts = [] if artifacts is None else artifacts

    def gh(path):
        if path.endswith("/artifacts?per_page=100"):
            return {"total_count": len(artifacts), "artifacts": artifacts}
        return run
    return gh


class Waiter:
    def __init__(self, fake, kind):
        self.fake, self.kind = fake, kind

    def wait(self, **kwargs):
        self.fake.log.append(("wait", self.kind))


class Paginator:
    def __init__(self, client, op):
        self.client, self.op = client, op

    def paginate(self, **kwargs):
        yield getattr(self.client, self.op)(**kwargs)


class Svc:
    """A fake boto3 client. Unknown read operations return empty pages."""

    def __init__(self, fake, name):
        self._fake, self._name = fake, name

    def get_paginator(self, op):
        return Paginator(self, op)

    def get_waiter(self, kind):
        return Waiter(self._fake, kind)

    def __getattr__(self, op):
        fake = self._fake

        def call(**kwargs):
            handler = getattr(fake, f"{self._name}_{op}", None)
            if handler is not None:
                return handler(**kwargs)
            if op.startswith(("describe_", "list_", "get_")):
                return {}
            fake.log.append((op, kwargs))
            return {}
        return call


class FakeAws:
    region = REGION

    def __init__(self):
        self.log = []          # every mutating call, in order
        self.deleted = set()
        self.account = ACCOUNT
        self.vpcs = [{"VpcId": "vpc-1", "Tags": [{"Key": "Name", "Value": f"{PREFIX}-vpc"},
                                                 {"Key": "ManagedBy", "Value": "terraform"}]}]
        self.subnets = ["subnet-1", "subnet-2"]
        self.sgs = [{"GroupId": "sg-d", "GroupName": "default"},
                    {"GroupId": "sg-l", "GroupName": f"{PREFIX}-lambda-1", "IpPermissions": [], "IpPermissionsEgress": [{"x": 1}]},
                    {"GroupId": "sg-r", "GroupName": f"{PREFIX}-rds-1", "IpPermissions": [{"y": 1}], "IpPermissionsEgress": []}]
        self.nats = [{"NatGatewayId": "nat-1", "State": "available", "CreateTime": CREATED + timedelta(minutes=5),
                      "NatGatewayAddresses": [{"AllocationId": "eipalloc-1"}]}]
        self.rds = [{"DBInstanceIdentifier": f"{PREFIX}-postgres", "DBSubnetGroup": {"VpcId": "vpc-1"},
                     "InstanceCreateTime": CREATED + timedelta(minutes=10), "DeletionProtection": False}]
        self.enis = [{"NetworkInterfaceId": "eni-rds", "Description": "RDSNetworkInterface"},
                     {"NetworkInterfaceId": "eni-nat", "Description": "Interface for NAT Gateway nat-1", "InterfaceType": "nat_gateway"}]
        self.functions = [{"FunctionName": f"{PREFIX}-honua"}, {"FunctionName": f"{PREFIX}-migration"},
                          {"FunctionName": "honua-cert-standing", "VpcConfig": {"VpcId": "vpc-standing"}}]
        self.apis = [{"ApiId": "api1", "Name": f"{PREFIX}-honua"}, {"ApiId": "apiX", "Name": "honua-demo-api"}]
        self.domains = [{"DomainName": DNS}]
        self.certs = [{"CertificateArn": "arn:cert1", "DomainName": DNS}]
        self.secrets = [{"Name": f"{PREFIX}/connection-string", "ARN": "arn:secret1"},
                        {"Name": "honua-demo-db/password", "ARN": "arn:secretX"}]
        self.log_groups = [{"logGroupName": f"/aws/lambda/{PREFIX}-honua"}, {"logGroupName": "/aws/lambda/honua-cert-x"}]
        self.roles = [{"RoleName": f"{PREFIX}-migration-2026"}, {"RoleName": "honua-cert-runner"}]
        self.records = [
            {"Name": DNS + ".", "Type": "A", "AliasTarget": {"DNSName": "d.example"}},
            {"Name": f"_abc123.{DNS}.", "Type": "CNAME", "TTL": 60, "ResourceRecords": [{"Value": "v"}]},
            {"Name": "other.cert.demo.honua.io.", "Type": "A"},
            {"Name": f"{RUN}-aws-serverless-redis-on.cert.demo.honua.io.", "Type": "A"},
        ]
        self.dns_names_present = lambda: {r["Name"] for r in self.records}

    # -- clients
    def client(self, name):
        return Svc(self, name)

    # -- STS / Route53
    def sts_get_caller_identity(self):
        return {"Account": self.account}

    def route53_get_hosted_zone(self, Id):
        return {"HostedZone": {"Name": "demo.honua.io."}}

    def route53_list_resource_record_sets(self, HostedZoneId):
        return {"ResourceRecordSets": list(self.records)}

    def route53_change_resource_record_sets(self, HostedZoneId, ChangeBatch):
        record = ChangeBatch["Changes"][0]["ResourceRecordSet"]
        self.log.append(("route53_delete", record["Name"]))
        self.records = [r for r in self.records if r["Name"] != record["Name"]]

    # -- EC2
    def ec2_describe_vpcs(self, Filters):
        name = Filters[0]["Values"][0]
        return {"Vpcs": [v for v in self.vpcs if tag_name(v) == name]}

    def ec2_describe_subnets(self, Filters):
        return {"Subnets": [{"SubnetId": s} for s in self.subnets]}

    def ec2_describe_internet_gateways(self, Filters):
        return {"InternetGateways": [{"InternetGatewayId": "igw-1"}] if "igw-1" not in self.deleted else []}

    def ec2_describe_route_tables(self, Filters):
        rts = [{"RouteTableId": "rtb-main", "Associations": [{"Main": True}], "Routes": []}]
        if "rtb-1" not in self.deleted:
            rts.append({"RouteTableId": "rtb-1", "Routes": [{"GatewayId": "igw-1"}],
                        "Associations": [{"RouteTableAssociationId": "rtbassoc-1"}]})
        return {"RouteTables": rts}

    def ec2_describe_nat_gateways(self, Filter):
        return {"NatGateways": [n for n in self.nats if n["NatGatewayId"] not in self.deleted]}

    def ec2_describe_security_groups(self, Filters=None, GroupIds=None):
        groups = [g for g in self.sgs if g["GroupId"] not in self.deleted]
        if GroupIds:
            groups = [g for g in groups if g["GroupId"] in GroupIds]
        return {"SecurityGroups": groups}

    def ec2_describe_network_interfaces(self, Filters):
        return {"NetworkInterfaces": [e for e in self.enis if e["NetworkInterfaceId"] not in self.deleted]}

    def ec2_describe_network_acls(self, Filters):
        return {"NetworkAcls": [{"NetworkAclId": "acl-1", "IsDefault": True}]}

    def ec2_describe_vpn_gateways(self, Filters):
        return {"VpnGateways": []}

    def ec2_delete_nat_gateway(self, NatGatewayId):
        self.log.append(("delete_nat", NatGatewayId))
        self.deleted.add(NatGatewayId)

    def ec2_release_address(self, AllocationId):
        assert "nat-1" in self.deleted, "EIP released before the NAT gateway was deleted"
        self.log.append(("release_eip", AllocationId))

    def ec2_revoke_security_group_ingress(self, **kw):
        self.log.append(("revoke_in", kw["GroupId"]))

    def ec2_revoke_security_group_egress(self, **kw):
        self.log.append(("revoke_out", kw["GroupId"]))

    def _delete(self, label, ident, **extra):
        self.log.append((label, ident))
        self.deleted.add(ident)
        if label == "delete_vpc":
            self.vpcs = []
        if label == "delete_rds":
            self.enis = [e for e in self.enis if e["NetworkInterfaceId"] != "eni-rds"]
            self.rds = [d for d in self.rds if d["DBInstanceIdentifier"] != ident]

    def ec2_delete_security_group(self, GroupId):
        self.sgs = [g for g in self.sgs if g["GroupId"] != GroupId]
        self._delete("delete_sg", GroupId)

    def ec2_disassociate_route_table(self, AssociationId):
        self.log.append(("disassociate", AssociationId))

    def ec2_delete_route_table(self, RouteTableId):
        self._delete("delete_rtb", RouteTableId)

    def ec2_delete_subnet(self, SubnetId):
        self.subnets.remove(SubnetId)
        self._delete("delete_subnet", SubnetId)

    def ec2_detach_internet_gateway(self, **kw):
        self.log.append(("detach_igw", kw["InternetGatewayId"]))

    def ec2_delete_internet_gateway(self, InternetGatewayId):
        self._delete("delete_igw", InternetGatewayId)

    def ec2_delete_vpc(self, VpcId):
        self._delete("delete_vpc", VpcId)

    # -- Lambda / RDS / API GW / ACM / secrets / logs / IAM
    def lambda_list_functions(self):
        return {"Functions": [f for f in self.functions if f["FunctionName"] not in self.deleted]}

    def lambda_delete_function(self, FunctionName):
        self._delete("delete_lambda", FunctionName)

    def rds_describe_db_instances(self):
        return {"DBInstances": [d for d in self.rds if d["DBInstanceIdentifier"] not in self.deleted]}

    def rds_delete_db_instance(self, DBInstanceIdentifier, SkipFinalSnapshot, DeleteAutomatedBackups):
        assert SkipFinalSnapshot is True
        self._delete("delete_rds", DBInstanceIdentifier)

    def rds_modify_db_instance(self, **kw):
        self.log.append(("disable_protection", kw["DBInstanceIdentifier"]))

    def apigatewayv2_get_apis(self, **kw):
        return {"Items": [a for a in self.apis if a["ApiId"] not in self.deleted]}

    def apigatewayv2_get_domain_names(self, **kw):
        return {"Items": [d for d in self.domains if d["DomainName"] not in self.deleted]}

    def apigatewayv2_get_api_mappings(self, **kw):
        return {"Items": []}

    def apigatewayv2_delete_api(self, ApiId):
        self._delete("delete_api", ApiId)

    def apigatewayv2_delete_domain_name(self, DomainName):
        self._delete("delete_domain", DomainName)

    def acm_list_certificates(self):
        return {"CertificateSummaryList": [c for c in self.certs if c["CertificateArn"] not in self.deleted]}

    def acm_delete_certificate(self, CertificateArn):
        self._delete("delete_cert", CertificateArn)

    def secretsmanager_list_secrets(self):
        return {"SecretList": [s for s in self.secrets if s["ARN"] not in self.deleted]}

    def secretsmanager_delete_secret(self, SecretId, ForceDeleteWithoutRecovery):
        assert ForceDeleteWithoutRecovery is True
        self._delete("delete_secret", SecretId)

    def logs_describe_log_groups(self, logGroupNamePrefix):
        return {"logGroups": [g for g in self.log_groups if g["logGroupName"] not in self.deleted]}

    def logs_delete_log_group(self, logGroupName):
        self._delete("delete_log_group", logGroupName)

    def iam_list_roles(self):
        return {"Roles": [r for r in self.roles if r["RoleName"] not in self.deleted]}

    def iam_delete_role(self, RoleName):
        self._delete("delete_role", RoleName)


def tag_name(vpc):
    return next(t["Value"] for t in vpc["Tags"] if t["Key"] == "Name")


@pytest.fixture
def cell():
    return Cell(RUN, "off", ACCOUNT, REGION)


def go(aws, cell, *, apply=False, gh=None, summary=None, **kw):
    return retire(aws, cell, apply=apply, grace_hours=24, summary_file=summary, gh=gh or make_gh(),
                  now=NOW, sleep=lambda s: None, **kw)


def mutations(aws):
    return [e for e in aws.log if e[0] != "wait"]


# -- happy path ------------------------------------------------------------

def test_dry_run_plans_everything_and_deletes_nothing(cell, tmp_path):
    aws, out = FakeAws(), tmp_path / "s.json"
    code, summary = go(aws, cell, summary=str(out))
    assert code == 0 and summary["status"] == "dry-run"
    assert mutations(aws) == []
    written = json.loads(out.read_text())
    assert written["schema"] == "honua.release-cell-untagged-retirement/v1"
    assert written["runId"] == RUN and written["cell"] == "aws-serverless/redis-off"
    res = written["resources"]
    assert res["vpc"] == ["vpc-1"] and res["nat_gateway"] == ["nat-1"] and res["eip"] == ["eipalloc-1"]
    assert sorted(res["lambda_function"]) == [f"{PREFIX}-honua", f"{PREFIX}-migration"]
    # the other cell (redis-on) and standing names are never in the plan
    assert len(res["route53_record"]) == 2
    assert "honua-cert" not in json.dumps(res) and "honua-demo" not in json.dumps(res)
    assert written["finishedAt"] and written["deleted"] == []


def test_apply_deletes_in_dependency_order_and_verifies_empty(cell, tmp_path):
    aws = FakeAws()
    code, summary = go(aws, cell, apply=True, summary=str(tmp_path / "s.json"))
    assert code == 0 and summary["status"] == "retired" and summary["failed"] == [] and summary["remaining"] == {}
    labels = [e[0] for e in mutations(aws)]
    first = {label: labels.index(label) for label in set(labels)}
    assert first["route53_delete"] < first["delete_lambda"] < first["delete_rds"] < first["delete_nat"]
    assert first["delete_nat"] < first["release_eip"] < first["delete_secret"]
    assert first["revoke_in"] < first["delete_sg"] < first["delete_subnet"] < first["detach_igw"] < first["delete_vpc"]
    # only this cell's records were removed; standing and sibling records survive
    assert {r["Name"] for r in aws.records} == {"other.cert.demo.honua.io.", f"{RUN}-aws-serverless-redis-on.cert.demo.honua.io."}
    assert "honua-cert-standing" not in aws.deleted and "apiX" not in aws.deleted and "arn:secretX" not in aws.deleted


# -- run refusals ------------------------------------------------------------

def test_refuses_run_still_in_progress(cell):
    aws = FakeAws()
    code, summary = go(aws, cell, apply=True, gh=make_gh(run_doc(status="in_progress", conclusion=None)))
    assert code == 2 and "not completed" in summary["refusal"] and mutations(aws) == []


def test_refuses_when_grace_not_elapsed(cell):
    aws = FakeAws()
    fresh = run_doc(updated_at=(NOW - timedelta(hours=3)).isoformat())
    code, summary = go(aws, cell, apply=True, gh=make_gh(fresh))
    assert code == 2 and "grace window" in summary["refusal"] and mutations(aws) == []


@pytest.mark.parametrize("override,needle", [
    ({"path": ".github/workflows/other.yml"}, "not an e2e-cloud-aws run"),
    ({"head_branch": "feature"}, "head_branch"),
    ({"id": 1}, "different run"),
])
def test_refuses_wrong_run_identity(cell, override, needle):
    code, summary = go(FakeAws(), cell, gh=make_gh(run_doc(**override)))
    assert code == 2 and needle in summary["refusal"]


def test_refuses_when_handoff_artifact_still_available(cell):
    aws = FakeAws()
    live = [{"name": "cloud-cell-state-aws-serverless-redis-off", "expired": False}]
    code, summary = go(aws, cell, apply=True, gh=make_gh(artifacts=live))
    assert code == 2 and "stateful" in summary["refusal"] and mutations(aws) == []


def test_expired_artifacts_allow_the_fallback(cell):
    expired = [{"name": "cloud-cell-handoff-x", "expired": True}]
    code, summary = go(FakeAws(), cell, gh=make_gh(artifacts=expired))
    assert code == 0 and summary["run"]["expiredArtifacts"] == ["cloud-cell-handoff-x"]


def test_refuses_when_artifact_listing_is_incomplete(cell):
    def gh(path):
        return {"total_count": 5, "artifacts": []} if "artifacts" in path else run_doc()
    code, summary = go(FakeAws(), cell, gh=gh)
    assert code == 2 and "cannot prove" in summary["refusal"]


def test_refuses_wrong_account(cell):
    aws = FakeAws()
    aws.account = "111111111111"
    code, summary = go(aws, cell, apply=True)
    assert code == 2 and "account" in summary["refusal"] and mutations(aws) == []


def test_refuses_resources_created_outside_the_run_window(cell):
    aws = FakeAws()
    aws.nats[0]["CreateTime"] = CREATED - timedelta(days=30)  # a different run with the same six digits
    code, summary = go(aws, cell, apply=True)
    assert code == 2 and "different run" in summary["refusal"] and mutations(aws) == []


# -- VPC identity ------------------------------------------------------------

def test_refuses_when_vpc_missing(cell):
    aws = FakeAws()
    aws.vpcs = []
    code, summary = go(aws, cell, apply=True)
    assert code == 2 and "found 0" in summary["refusal"] and mutations(aws) == []


def test_refuses_duplicate_vpc(cell):
    aws = FakeAws()
    aws.vpcs.append(copy.deepcopy(aws.vpcs[0]))
    aws.vpcs[1]["VpcId"] = "vpc-2"
    code, summary = go(aws, cell, apply=True)
    assert code == 2 and "found 2" in summary["refusal"] and mutations(aws) == []


def test_refuses_vpc_without_managed_by_terraform(cell):
    aws = FakeAws()
    aws.vpcs[0]["Tags"] = [{"Key": "Name", "Value": f"{PREFIX}-vpc"}]
    code, summary = go(aws, cell, apply=True)
    assert code == 2 and "ManagedBy" in summary["refusal"]


# -- standing names / unexpected resources ------------------------------------

def test_refuses_standing_named_security_group_in_the_vpc(cell):
    aws = FakeAws()
    aws.sgs.append({"GroupId": "sg-s", "GroupName": "honua-cert-shared"})
    code, summary = go(aws, cell, apply=True)
    assert code == 2 and "standing" in summary["refusal"] and mutations(aws) == []


def test_refuses_standing_named_rds_in_the_vpc(cell):
    aws = FakeAws()
    aws.rds.append({"DBInstanceIdentifier": "honua-demo-db", "DBSubnetGroup": {"VpcId": "vpc-1"}})
    code, summary = go(aws, cell, apply=True)
    assert code == 2 and "standing" in summary["refusal"] and mutations(aws) == []


def test_refuses_unexpected_resource_in_the_vpc(cell):
    aws = FakeAws()
    aws.sgs.append({"GroupId": "sg-z", "GroupName": "somebody-elses"})
    code, summary = go(aws, cell, apply=True)
    assert code == 2 and "does not carry the cell prefix" in summary["refusal"] and mutations(aws) == []


def test_refuses_unexpected_network_interface(cell):
    aws = FakeAws()
    aws.enis.append({"NetworkInterfaceId": "eni-x", "Description": "my laptop tunnel"})
    code, summary = go(aws, cell, apply=True)
    assert code == 2 and "eni-x" in summary["refusal"] and mutations(aws) == []


def test_refuses_foreign_lambda_attached_to_the_vpc(cell):
    aws = FakeAws()
    aws.functions.append({"FunctionName": "other-fn", "VpcConfig": {"VpcId": "vpc-1"}})
    code, summary = go(aws, cell, apply=True)
    assert code == 2 and "foreign Lambda" in summary["refusal"]


def test_refuses_unsupported_type_under_the_prefix(cell):
    aws = FakeAws()
    aws.ecr_describe_repositories = lambda: {"repositories": [{"repositoryName": f"{PREFIX}-worker-gdal"}]}
    code, summary = go(aws, cell, apply=True)
    assert code == 2 and "ecr_repository" in summary["refusal"] and mutations(aws) == []


def test_refuses_rds_deletion_protection_unless_planned(cell):
    aws = FakeAws()
    aws.rds[0]["DeletionProtection"] = True
    code, summary = go(aws, cell, apply=True)
    assert code == 2 and "deletion protection" in summary["refusal"] and mutations(aws) == []
    code, summary = go(aws, cell, apply=True, disable_rds_protection=True)
    assert code == 0 and ("disable_protection", f"{PREFIX}-postgres") in aws.log


def test_unexpected_dns_record_type_refuses(cell):
    aws = FakeAws()
    aws.records.append({"Name": DNS + ".", "Type": "TXT"})
    code, summary = go(aws, cell)
    assert code == 2 and "record type" in summary["refusal"]


# -- post-delete verification ----------------------------------------------------

def test_reports_incomplete_when_resources_remain_after_delete(cell, tmp_path):
    aws = FakeAws()
    def stubborn_secret_delete(SecretId, ForceDeleteWithoutRecovery):
        aws.log.append(("delete_secret_ignored", SecretId))  # AWS accepted, but it is still listed
    aws.secretsmanager_delete_secret = stubborn_secret_delete
    code, summary = go(aws, cell, apply=True, summary=str(tmp_path / "s.json"))
    assert code == 1 and summary["status"] == "incomplete"
    assert summary["remaining"]["secret"] == ["arn:secret1"]
    assert json.loads((tmp_path / "s.json").read_text())["status"] == "incomplete"


def test_delete_failure_is_recorded_and_never_reported_as_success(cell):
    aws = FakeAws()

    def locked(VpcId):
        raise ClientError("DependencyViolation")
    aws.ec2_delete_vpc = locked
    code, summary = go(aws, cell, apply=True)
    assert code == 1 and summary["status"] == "incomplete"
    assert any(f["type"] == "vpc" for f in summary["failed"])


def test_secret_outside_prefix_is_never_force_deleted(cell):
    deleter = tool.Deleter(FakeAws(), cell)
    with pytest.raises(RetirementRefused):
        deleter.secret({"id": "arn:x", "name": "honua-demo-db/password"})


# -- input validation ----------------------------------------------------------

@pytest.mark.parametrize("args", [
    dict(run_id="abc", redis="off"), dict(run_id=RUN, redis="maybe"),
    dict(run_id=RUN, redis="off", account_id="1"), dict(run_id=RUN, redis="off", region="mars"),
])
def test_cell_identity_validation(args):
    base = dict(run_id=RUN, redis="off", account_id=ACCOUNT, region=REGION)
    base.update(args)
    with pytest.raises(RetirementRefused):
        Cell(**base)


def test_cell_prefix_and_dns_names():
    on = Cell("39954906623", "on", ACCOUNT, REGION)
    assert on.prefix == "honuarawsse399549-it" and on.vpc_name == "honuarawsse399549-it-vpc"
    assert on.dns_name == "39954906623-aws-serverless-redis-on.cert.demo.honua.io"
    assert not on.owns_name("honuarawsse399549-itx-foo") and on.owns_name("honuarawsse399549-it-foo")
    assert not on.owns_dns("_zz.39954906623-aws-serverless-redis-on.cert.demo.honua.io.", "CNAME")  # hex only
    assert on.owns_dns("_ab12.39954906623-aws-serverless-redis-on.cert.demo.honua.io.", "CNAME")
    assert not on.owns_dns("_ab12.39954906623-aws-serverless-redis-on.cert.demo.honua.io.", "A")


def test_main_defaults_to_dry_run_and_refuses_bad_grace(monkeypatch, tmp_path):
    aws = FakeAws()
    argv = ["--run-id", RUN, "--redis", "off", "--account-id", ACCOUNT, "--region", REGION,
            "--summary-file", str(tmp_path / "s.json")]
    monkeypatch.setattr(tool, "utcnow", lambda: NOW)
    monkeypatch.setattr(tool, "retire", lambda *a, **k: (0, {}) if k["apply"] is False else (9, {}))
    assert tool.main(argv, aws=aws, gh=make_gh()) == 0
    assert tool.main(argv + ["--grace-hours", "0"], aws=aws, gh=make_gh()) == 2
    with pytest.raises(SystemExit):
        tool.main(argv + ["--apply", "--dry-run"], aws=aws)

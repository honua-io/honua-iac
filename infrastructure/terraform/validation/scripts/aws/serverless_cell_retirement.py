"""Validate complete retirement of a disposable release cell before lifting guards.

This is not an ordinary deployment option. Callers must restore authenticated
original state and run this only from a checked-in cleanup workflow. The ordinary
module retains its literal prevent_destroy guards. No AWS writes occur here.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import subprocess
from pathlib import Path

RUN_TAG = "honua-release:run-id"
CELL_TAG = "honua-release:cell"
OVERRIDE_NAME = "release_cell_retirement_override.tf.json"
SETTINGS = "module.honua.aws_secretsmanager_secret.runtime_settings["
VERSIONS = "module.honua.aws_secretsmanager_secret_version.runtime_settings["

# Resources without tags must be children of an independently owned resource.
# An IAM attachment may name an AWS-managed policy, but only its owned role is
# changed. A Route53 record is handled separately because its zone is shared.
PARENTS = {
    "aws_iam_role_policy": ("role",),
    "aws_iam_role_policy_attachment": ("role",),
    "aws_lambda_alias": ("function_name",),
    "aws_lambda_permission": ("function_name",),
    "aws_lambda_function_event_invoke_config": ("function_name",),
    "aws_lambda_invocation": ("function_name",),
    "aws_secretsmanager_secret_version": ("secret_id",),
    "aws_security_group_rule": ("security_group_id",),
    "aws_apigatewayv2_integration": ("api_id",),
    "aws_apigatewayv2_route": ("api_id",),
    "aws_apigatewayv2_api_mapping": ("api_id", "domain_name"),
    "aws_acm_certificate_validation": ("certificate_arn",),
    "aws_cloudwatch_event_target": ("rule",),
    "aws_cloudwatch_log_metric_filter": ("log_group_name",),
    "aws_ecr_lifecycle_policy": ("repository",),
    "aws_ecr_repository_policy": ("repository",),
    "aws_route": ("route_table_id",),
    "aws_route_table_association": ("route_table_id", "subnet_id"),
    "aws_main_route_table_association": ("route_table_id", "vpc_id"),
    "aws_db_proxy_default_target_group": ("db_proxy_name",),
    "aws_db_proxy_target": ("db_proxy_name", "db_instance_identifier"),
    "aws_scheduler_schedule": ("group_name",),
    "aws_sns_topic_subscription": ("topic_arn",),
}
LOCAL_TYPES = {"random_password", "random_uuid", "random_id", "null_resource", "terraform_data"}


class RetirementRefused(ValueError):
    pass


def resources(module):
    yield from (r for r in module.get("resources", []) if r.get("mode") == "managed")
    for child in module.get("child_modules", []):
        yield from resources(child)


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def inventory(state, *, run_id, cell, account_id, region):
    """Refuse foreign state, mixed ownership, and unowned child resources."""
    if not re.fullmatch(r"[1-9][0-9]+", run_id) or cell not in (
        "aws-serverless/redis-off", "aws-serverless/redis-on"
    ) or not re.fullmatch(r"[0-9]{12}", account_id):
        raise RetirementRefused("invalid original cell identity")
    rows = list(resources(state.get("values", {}).get("root_module", {})))
    if not rows or len({r["address"] for r in rows}) != len(rows):
        raise RetirementRefused("missing or duplicate original resources")
    owned = set()
    untagged = []
    records = []
    for row in rows:
        address, kind, values = row["address"], row["type"], row.get("values") or {}
        if not address.startswith("module.honua."):
            raise RetirementRefused(f"resource outside the cell module: {address}")
        if kind in LOCAL_TYPES:
            records.append({"address": address, "type": kind, "id": values.get("id")})
            continue
        if not kind.startswith("aws_"):
            raise RetirementRefused(f"unexpected resource provider: {address}")
        if not isinstance(values.get("id"), str) or not values["id"]:
            raise RetirementRefused(f"missing original resource identity: {address}")
        tags = values.get("tags_all") or values.get("tags") or {}
        if tags:
            if tags.get(RUN_TAG) != run_id or tags.get(CELL_TAG) != cell:
                raise RetirementRefused(f"foreign resource ownership: {address}")
            for key in ("id", "arn", "name", "function_name", "domain_name", "identifier"):
                value = values.get(key)
                if isinstance(value, str) and value:
                    owned.add(value)
        else:
            untagged.append(row)
        arn = values.get("arn")
        if isinstance(arn, str) and arn.startswith("arn:"):
            parts = arn.split(":", 5)
            if len(parts) != 6 or parts[1] != "aws" or parts[3] not in ("", region) or parts[4] not in ("", account_id):
                raise RetirementRefused(f"foreign account or region: {address}")
        records.append({"address": address, "type": kind, "id": values.get("id")})
    domain = run_id + "-" + cell.replace("/", "-") + ".cert."
    for row in untagged:
        values, kind = row["values"], row["type"]
        if kind == "aws_route53_record":
            name = str(values.get("name", "")).rstrip(".")
            if name.startswith(domain) or (name.startswith("_") and "." + domain in name):
                continue
        if kind not in PARENTS or not all(values.get(key) in owned for key in PARENTS[kind]):
            raise RetirementRefused(f"unowned child resource: {row['address']}")
    functions = [r["values"].get("arn") for r in rows if r["type"] == "aws_lambda_function"]
    settings = [r for r in rows if r["address"].startswith(SETTINGS)]
    versions = [r for r in rows if r["address"].startswith(VERSIONS)]
    if not functions or any(not f for f in functions) or not settings or len(settings) != len(versions):
        raise RetirementRefused("full Lambda and runtime-settings inventory required")
    settings_ids = {r["values"]["id"] for r in settings}
    if {r["values"].get("secret_id") for r in versions} != settings_ids:
        raise RetirementRefused("runtime-settings version/secret inventory mismatch")
    return {"schema": "honua.release-cell-retirement/v1", "runId": run_id, "cell": cell,
            "accountId": account_id, "region": region, "resources": records,
            "functions": sorted(functions),
            "settings": sorted({r["values"][key] for r in settings for key in ("name", "arn")}),
            "stateSha256": digest(state)}


def observe_lambda_readers(client, record):
    """Read every published function version in the region, not only $LATEST.

    API failures propagate. A function outside the owned destroy set referencing
    a retained settings document prevents retirement even if it has no alias.
    """
    seen = set()
    versions = 0
    for page in client.get_paginator("list_functions").paginate():
        for function in page.get("Functions", []):
            arn = function["FunctionArn"]
            seen.add(arn)
            for version_page in client.get_paginator("list_versions_by_function").paginate(FunctionName=arn):
                for version in version_page.get("Versions", []):
                    versions += 1
                    environment = version.get("Environment", {})
                    if environment.get("Error"):
                        raise RetirementRefused("published function environment could not be inspected")
                    for reference in environment.get("Variables", {}).values():
                        if isinstance(reference, str) and reference.startswith("aws:secretsmanager:"):
                            secret = reference.removeprefix("aws:secretsmanager:").split("?", 1)[0]
                            if secret in record["settings"] and arn not in record["functions"]:
                                raise RetirementRefused("a foreign published Lambda version reads retained settings")
    if not set(record["functions"]) <= seen:
        raise RetirementRefused("original function inventory changed; reconcile state before retirement")
    return {"functionCount": len(seen), "versionCount": versions, "foreignReaders": 0}


def prepare_override(module, record, observation):
    """Only a reviewed complete-cell destroy plan may consume this override."""
    module = Path(module)
    source = (module / "runtime-settings.tf").read_text()
    if source.count("prevent_destroy = true") != 2 or observation.get("foreignReaders") != 0:
        raise RetirementRefused("unexpected retention source or unresolved settings readers")
    path = module / OVERRIDE_NAME
    if path.exists():
        raise RetirementRefused("retirement override already exists")
    value = {"resource": {kind: {"runtime_settings": {"lifecycle": {"prevent_destroy": False}}}
                          for kind in ("aws_secretsmanager_secret", "aws_secretsmanager_secret_version")}}
    path.write_text(json.dumps(value, indent=2) + "\n")
    return {**record, "lambdaObservation": observation, "overrideSha256": hashlib.sha256(path.read_bytes()).hexdigest()}


def validate_plan(plan, record):
    """No apply/update/targeted deletion can consume the retirement override."""
    if plan.get("errored") or plan.get("applyable") is False or plan.get("complete") is False:
        raise RetirementRefused("retirement plan is incomplete or invalid")
    expected = {r["address"]: r for r in record["resources"]}
    changes = {r["address"]: r for r in plan.get("resource_changes", []) if r.get("mode") == "managed"}
    if len(changes) != len(expected) or set(changes) != set(expected):
        raise RetirementRefused("retirement must destroy the entire original cell")
    for address, change in changes.items():
        before = change.get("change", {}).get("before") or {}
        if change.get("type") != expected[address]["type"] or change.get("change", {}).get("actions") != ["delete"]:
            raise RetirementRefused(f"retirement plan contains a non-delete action: {address}")
        if before.get("id") != expected[address]["id"]:
            raise RetirementRefused(f"retirement plan replaced an original resource: {address}")
    return {"planSha256": digest(plan), "destroyCount": len(changes)}


def retire(root, module, *, run_id, cell, account_id, region, variables,
           lambda_client, sts_client, run=subprocess.run):
    """Apply only a complete validated delete plan in a private workflow checkout.

    The caller authenticates and restores the original sealed state first. It
    must reseal the updated state on any failure. This function never discards
    state, changes the tracked module, or runs an ordinary apply/destroy command.
    Raw Terraform output, plans and state stay in the private working directory.
    A successful result is a Terraform retirement receipt, not a zero-cost claim:
    Secrets Manager's recovery window and independent absence checks remain due.
    """
    root, module = Path(root).resolve(), Path(module).resolve()
    expected_module = root.parent.parent / "modules" / "aws-serverless"
    if root.name != "aws-serverless" or root.parent.name != "examples" or module != expected_module:
        raise RetirementRefused("retirement requires the original aws-serverless example and module")
    if sts_client.get_caller_identity()["Account"] != account_id or lambda_client.meta.region_name != region:
        raise RetirementRefused("retirement caller account or region differs")
    if any(not isinstance(v, str) or not (v in ("-input=false", "-no-color") or
               v.startswith("-var=") or v.startswith("-var-file=")) for v in variables):
        raise RetirementRefused("only reviewed Terraform input variables may accompany retirement")
    directory = root / ".release-cell-retirement"
    directory.mkdir(mode=0o700, exist_ok=True)
    os.chmod(directory, 0o700)
    receipt_path = directory / "receipt.json"
    if receipt_path.exists():
        raise RetirementRefused("prior retirement exists; restore its retained state and reconcile before retry")
    plan_path = directory / "destroy.tfplan"
    override_path = module / OVERRIDE_NAME
    if override_path.exists() or plan_path.exists():
        raise RetirementRefused("preexisting retirement override or plan")

    def private_json(path, value):
        with os.fdopen(os.open(path, os.O_CREAT | os.O_TRUNC | os.O_WRONLY, 0o600), "w") as stream:
            json.dump(value, stream, sort_keys=True)

    def terraform(label, *args):
        result = run(["terraform", f"-chdir={root}", *args], text=True, capture_output=True, check=False)
        # Diagnostics may contain input credentials: never echo them or upload
        # this directory as a plaintext artifact.
        private_json(directory / (label + ".private.json"),
                     {"stdout": result.stdout, "stderr": result.stderr, "exitCode": result.returncode})
        if result.returncode:
            raise RetirementRefused("Terraform " + label + " failed; private state and diagnostics retained")
        return result.stdout

    original = json.loads(terraform("original-state", "show", "-json"))
    record = inventory(original, run_id=run_id, cell=cell, account_id=account_id, region=region)
    observed = observe_lambda_readers(lambda_client, record)
    receipt = {**record, "status": "prepared", "terraformRetired": False,
               "independentAbsenceVerified": False, "costReconciled": False}
    private_json(receipt_path, receipt)
    try:
        receipt.update(prepare_override(module, record, observed))
        terraform("destroy-plan", "plan", "-destroy", "-out=" + str(plan_path), *variables)
        plan = json.loads(terraform("inspect-plan", "show", "-json", str(plan_path)))
        receipt.update(validate_plan(plan, record))
        receipt["savedPlanSha256"] = hashlib.sha256(plan_path.read_bytes()).hexdigest()
        # Observe again immediately before consuming the exact inspected plan.
        receipt["lambdaObservation"] = observe_lambda_readers(lambda_client, record)
        if hashlib.sha256(plan_path.read_bytes()).hexdigest() != receipt["savedPlanSha256"]:
            raise RetirementRefused("saved retirement plan changed after inspection")
        receipt["status"] = "applying"
        private_json(receipt_path, receipt)
        terraform("apply-delete-plan", "apply", "-input=false", "-no-color", str(plan_path))
        remaining = json.loads(terraform("remaining-state", "show", "-json"))
        if list(resources(remaining.get("values", {}).get("root_module", {}))):
            raise RetirementRefused("managed resources remain after retirement")
        receipt.update(status="terraform-retired", terraformRetired=True)
        return receipt
    except Exception as error:
        receipt.update(status="incomplete", failureType=type(error).__name__)
        raise
    finally:
        # Retention is restored even after failed planning/apply. Do not delete
        # original/updated state or the private recovery evidence.
        override_path.unlink(missing_ok=True)
        private_json(receipt_path, receipt)

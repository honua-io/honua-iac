#!/usr/bin/env python3
"""Simulate the topology deploy identity against AWS IAM. Read-only.

Input is `terraform test -json -verbose -filter=tests/topology.tftest.hcl`
from bootstrap/aws-exec-identity. The script sends those rendered policy
documents to iam:SimulateCustomPolicy. It does not create, change, or delete
AWS resources.

AWS credentials need iam:SimulateCustomPolicy. Concrete action names only:
SimulateCustomPolicy does not accept a wildcard in ActionNames. The region
condition is supplied as aws:RequestedRegion=us-east-1, which matches the
test's region and leaves Route 53 (no region condition) evaluable.
"""

from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor
import argparse
from collections import defaultdict
import json
import subprocess
import time
from pathlib import Path

REPO = Path(__file__).resolve().parents[5]
MANIFEST_DIR = REPO / "infrastructure" / "terraform" / "bootstrap" / "aws-exec-identity" / "manifests"
REQUIRED_RUNS = (
    "ecs_with_redis",
    "ecs_without_redis",
    "eks",
    "lambda_without_redis",
    "lambda_with_domain",
)
ACCOUNT = "123456789012"
REGION = "us-east-1"
BOUNDARY = f"arn:aws:iam::{ACCOUNT}:policy/honua-prod-workload-boundary"
DEPLOYMENT_ROLE = f"arn:aws:iam::{ACCOUNT}:role/honua-prod-deploy"
WORKLOAD_ROLE = f"arn:aws:iam::{ACCOUNT}:role/honua-task"
STATE_OBJECT = "arn:aws:s3:::honua-tfstate-test/terraform.tfstate"
WRONG_SERVICES = (
    "ecs-tasks.amazonaws.com",
    "lambda.amazonaws.com",
    "eks.amazonaws.com",
    "ec2.amazonaws.com",
    "batch.amazonaws.com",
    "pods.eks.amazonaws.com",
    "scheduler.amazonaws.com",
)


def aws(payload: dict) -> dict:
    last_error = "iam simulate-custom-policy failed"
    for delay in [0, 10, 30, 60, 120, 60]:
        if delay:
            time.sleep(delay)
        result = subprocess.run(
            ["aws", "iam", "simulate-custom-policy", "--cli-input-json", json.dumps(payload), "--output", "json"],
            text=True,
            capture_output=True,
        )
        if result.returncode == 0:
            return json.loads(result.stdout)
        last_error = result.stderr.strip().splitlines()[-1] if result.stderr.strip() else last_error
        if not any(token in result.stderr.lower() for token in (
            "could not connect",
            "could not resolve",
            "connection reset",
            "timeout",
            "timed out",
            "throttl",
        )):
            raise RuntimeError(last_error)
    raise RuntimeError(last_error)


def load_runs(path: Path) -> dict[str, dict]:
    runs: dict[str, dict] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        event = json.loads(line)
        if event.get("type") != "test_plan" or event.get("@testfile") != "tests/topology.tftest.hcl":
            continue
        name = event.get("@testrun")
        changes = event.get("test_plan", {}).get("output_changes", {})
        if "deploy_identity_contract" not in changes or "deployment_policy_json" not in changes:
            continue
        runs[name] = {key: value["after"] for key, value in changes.items() if "after" in value}
    missing = [name for name in REQUIRED_RUNS if name not in runs]
    if missing:
        raise ValueError(
            "missing topology test plans: " + ", ".join(missing)
            + ". Run terraform test -json -verbose -filter=tests/topology.tftest.hcl"
        )
    return runs


def manifests() -> dict[str, dict]:
    found = {}
    for path in sorted(MANIFEST_DIR.glob("*.json")):
        found[path.stem] = json.loads(path.read_text(encoding="utf-8"))
    return found


def context_entries(context: dict) -> list[dict]:
    entries = []
    for key, value in context.items():
        values = value if isinstance(value, list) else [value]
        entries.append({
            "ContextKeyName": key,
            "ContextKeyValues": values,
            "ContextKeyType": "stringList" if isinstance(value, list) else "string",
        })
    return entries


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("terraform_test_jsonl", type=Path)
    parser.add_argument("--receipt", type=Path, required=True)
    args = parser.parse_args()

    runs = load_runs(args.terraform_test_jsonl)
    files = manifests()
    cases = []

    def add(run: str, name: str, action: str, resource: str, expected: str, context: dict) -> None:
        cases.append((run, name, action, resource, expected, {"aws:RequestedRegion": REGION, **context}))

    for run, output in sorted(runs.items()):
        selected = set(output["deploy_identity_contract"]["manifests"])
        policies = [output["deployment_policy_json"], output["deployment_workload_policy_json"], *output["deployment_extra_policy_json"].values()]
        pass_services = sorted({
            service
            for manifest_id in selected
            for service in files[manifest_id]["pass_role_services"]
        })
        allowed_services = pass_services or ["ecs-tasks.amazonaws.com"]
        wrong_service = next(service for service in WRONG_SERVICES if service not in pass_services)

        for manifest_id in sorted(selected):
            for action in files[manifest_id]["simulate_allow"]:
                resource = "*"
                extra: dict = {}
                if action == "iam:CreateRole":
                    resource = f"arn:aws:iam::{ACCOUNT}:role/honua-workload"
                    extra["iam:PermissionsBoundary"] = BOUNDARY
                elif action == "iam:PassRole":
                    resource = WORKLOAD_ROLE
                    extra["iam:PassedToService"] = allowed_services[0]
                add(run, f"allow-{manifest_id}-{action}", action, resource, "allowed", extra)

        granted = set()
        for manifest_id in selected:
            body = files[manifest_id]
            granted.update(body["region_actions"])
            granted.update(body["global_actions"])
            for statement in body["iam_statements"]:
                granted.update(statement["actions"])

        def granted_action(action: str) -> bool:
            return action in granted

        # Another module's sample action is out of topology only when this
        # shape does not grant it.
        for manifest_id, body in sorted(files.items()):
            if manifest_id in selected or manifest_id == "iam-workload":
                continue
            for action in body["simulate_allow"]:
                if granted_action(action):
                    continue
                add(run, f"deny-outside-{manifest_id}-{action}", action, "*", "implicitDeny", {})

        add(run, "deny-create-user", "iam:CreateUser", f"arn:aws:iam::{ACCOUNT}:user/escalation", "explicitDeny", {})
        add(run, "allow-bounded-trust-update", "iam:UpdateAssumeRolePolicy", WORKLOAD_ROLE,
            "allowed", {"iam:PermissionsBoundary": BOUNDARY})
        add(run, "deny-unbounded-trust-update", "iam:UpdateAssumeRolePolicy", WORKLOAD_ROLE,
            "implicitDeny", {})
        for index in output["deployment_extra_policy_json"]:
            add(run, f"deny-mutate-extra-policy-{index}", "iam:CreatePolicyVersion",
                f"arn:aws:iam::{ACCOUNT}:policy/honua-prod-deploy-{index}", "explicitDeny", {})
        add(run, "deny-state-object", "s3:GetObject", STATE_OBJECT, "explicitDeny", {})
        add(
            run,
            "deny-pass-self",
            "iam:PassRole",
            DEPLOYMENT_ROLE,
            "explicitDeny",
            {"iam:PassedToService": allowed_services[0]},
        )
        add(
            run,
            "deny-pass-wrong-service",
            "iam:PassRole",
            WORKLOAD_ROLE,
            "implicitDeny",
            {"iam:PassedToService": wrong_service},
        )
        # Stash the policy list on the case via the run map. evaluate looks it up.
        output["_policies"] = policies

    # IAM can evaluate multiple actions for the same resource and context in
    # one request. Keep each batch small so responses remain within one page.
    groups = defaultdict(list)
    for fixture in cases:
        run, _, _, resource, _, context = fixture
        groups[(run, resource, json.dumps(context, sort_keys=True))].append(fixture)
    batches = []
    for fixtures in groups.values():
        for offset in range(0, len(fixtures), 25):
            batches.append(fixtures[offset:offset + 25])

    def evaluate(fixtures):
        run, _, _, resource, _, context = fixtures[0]
        payload = {
            "ActionNames": sorted({fixture[2] for fixture in fixtures}),
            "ResourceArns": [resource],
            "ContextEntries": context_entries(context),
            "PolicyInputList": runs[run]["_policies"],
        }
        decisions = {item["EvalActionName"].lower(): item["EvalDecision"] for item in aws(payload)["EvaluationResults"]}
        receipts = []
        for run, name, action, _, expected, _ in fixtures:
            actual = decisions[action.lower()]
            receipts.append({"run": run, "case": name, "action": action, "expected": expected, "actual": actual})
            print(f"{run}/{name}: {actual}", flush=True)
        return receipts

    with ThreadPoolExecutor(max_workers=4) as pool:
        receipts = [receipt for group in pool.map(evaluate, batches) for receipt in group]
    args.receipt.parent.mkdir(parents=True, exist_ok=True)
    args.receipt.write_text(json.dumps({"source": str(args.terraform_test_jsonl), "cases": receipts}, indent=2) + "\n", encoding="utf-8")
    failures = [item for item in receipts if item["expected"] != item["actual"]]
    if failures:
        raise AssertionError(json.dumps(failures, indent=2))
    print(f"PASS: {len(receipts)} AWS IAM decisions matched the topology manifests")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

"""Compare every pinned Launch Stack handler permission with rendered gate IAM."""
import argparse
import json
from pathlib import Path

from actions import authorization_actions
from iam import decision
from gaps import unresolved
from operations import operation_requests
from scope import excluded


def rendered_statements(path):
    policies = {}
    for line in path.read_text().splitlines():
        event = json.loads(line)
        if event.get("@testrun") != "shared_account_policy_quotas_with_deployment_sized_inputs":
            continue
        for resource in event.get("test_plan", {}).get("resource_changes", []):
            if resource["type"] in {"aws_iam_policy", "aws_iam_role_policy"}:
                value = resource["change"]["after"].get("policy")
                if value:
                    policies[resource["address"]] = json.loads(value)["Statement"]
    required = {"aws_iam_role_policy.cloudformation", "aws_iam_policy.cloudformation_fences"}
    if not required.issubset(policies):
        raise ValueError("Actual Terraform mock plan must contain both CloudFormation policies")
    return sum((policies[key] for key in required), [])


def audit(snapshot, statements):
    rows = []
    for template in snapshot["templates"]:
        for name, resource in template["resources"].items():
            identity = {"resource": name, "type": resource["Type"]}
            rows.extend({**identity, **row} for row in audit_resource(resource, snapshot, statements))
    return rows


def audit_resource(resource, snapshot, statements):
    resource_type = resource["Type"]
    if resource_type.startswith("Custom::") and "AuditRuntimeActions" in resource:
        return [{"decision": "UnverifiedRuntimePolicy", "handler": "runtime", "action": action}
                for action in resource["AuditRuntimeActions"] or ["no-static-sdk-call"]]
    if resource_type.startswith("Custom::"):
        return [{"decision": "UnmappedCustomHandler", "handler": "runtime", "action": "unknown"}]
    schema = snapshot["schemas"][resource_type]
    handlers = {k: v for k, v in schema["handlers"].items() if k in {"create", "read", "update", "delete"}}
    handlers["tag"] = schema.get("tagging", {}).get("permissions", [])
    rows = []
    for handler, actions in handlers.items():
        for action in actions:
            row = {"handler": handler, "action": action}
            omission = excluded(resource, action)
            if omission:
                rows.append({**row, "decision": "NotApplicable", "reason": omission})
                continue
            service = snapshot["authorization"].get(action.split(":")[0].lower())
            spec = {"type": resource_type, "handler": handler, "action": action,
                    "schema": schema, "properties": resource.get("Properties", {})}
            request, result = evaluate(spec, service, statements)
            rows.append({**row, "request": request, "decision": result})
    return rows


def evaluate(spec, service, statements):
    try:
        requests = []
        for action in authorization_actions(spec["action"]):
            expanded = operation_requests({**spec, "action": action}, service) if service else None
            if expanded is None:
                return None, "UnknownAction"
            requests.extend(expanded)
        results = {decision(statements, request) for request in requests}
        result = next((r for r in ("Deny", "ImplicitDeny", "Allow") if r in results))
        return requests, result
    except ValueError as error:
        return None, str(error)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("plan", type=Path)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--expected-gaps", type=Path, help="Regression mode; known gaps remain NOT PASS")
    args = parser.parse_args()
    snapshot = json.loads(Path(__file__).with_name("launch-stack.json").read_text())
    rows = audit(snapshot, rendered_statements(args.plan))
    args.report.write_text(json.dumps(rows, indent=2) + "\n")
    failures = [row for row in rows if row["decision"] not in {"Allow", "NotApplicable"}]
    for row in failures:
        print(f'{row["decision"]}: {row["type"]} {row["handler"]} {row["action"]}')
    print(f"{len(rows)} handler checks; {len(failures)} unresolved")
    if args.expected_gaps:
        expected = json.loads(args.expected_gaps.read_text())
        if unresolved(rows) != expected:
            print("Unresolved permission inventory changed; review the machine-readable report")
            raise SystemExit(1)
        print("Known-gap regression matched; authorization sweep remains NOT PASS")
        return
    raise SystemExit(bool(failures))


if __name__ == "__main__":
    main()

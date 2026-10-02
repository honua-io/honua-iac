#!/usr/bin/env python3
"""Retain ECS startup diagnostics before a certification cell is destroyed.

Read-only AWS calls. Never retrieve secret values or task-definition environment.
The caller must upload the output directory even when collection is incomplete.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess


def capture(cluster, services, log_group, output_dir, region, run=subprocess.run):
    # Logs can include operator data. Create the evidence privately from the start.
    os.umask(0o077)
    output_dir = Path(output_dir)
    output_dir.mkdir(parents=True, exist_ok=False)
    failures = []

    def aws(label, *args):
        try:
            result = run(["aws", "--region", region, "--output", "json", *args],
                         text=True, capture_output=True, timeout=60, check=False)
            (output_dir / f"{label}.stderr.txt").write_text(result.stderr)
            (output_dir / f"{label}.json").write_text(result.stdout)
            if result.returncode:
                failures.append(label)
                return None
            return json.loads(result.stdout)
        except (OSError, subprocess.TimeoutExpired, json.JSONDecodeError) as error:
            (output_dir / f"{label}.error.txt").write_text(str(error))
            failures.append(label)
            return None

    aws("services", "ecs", "describe-services", "--cluster", cluster, "--services", *services)
    for service_index, service in enumerate(services):
        for status in ("STOPPED", "RUNNING"):
            label = f"service-{service_index}-{status.lower()}"
            listing = aws(label, "ecs", "list-tasks", "--cluster", cluster,
                          "--service-name", service, "--desired-status", status)
            arns = (listing or {}).get("taskArns", [])
            # describe-tasks permits at most 100 tasks per request. AWS CLI pagination
            # gathers all list-tasks pages, including tasks from a partial deployment.
            for index in range(0, len(arns), 100):
                aws(f"{label}-details-{index // 100}", "ecs", "describe-tasks",
                    "--cluster", cluster, "--tasks", *arns[index:index + 100])
    # The log group is cell-scoped. Capture all streams (including init failures)
    # while they still exist, even when no stopped task remains in ECS's short history.
    aws("container-logs", "logs", "filter-log-events", "--log-group-name", log_group)
    summary = {"cluster": cluster, "services": services, "log_group": log_group,
               "complete": not failures, "failed_collections": failures}
    (output_dir / "collection.json").write_text(json.dumps(summary, indent=2) + "\n")
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cluster", required=True)
    parser.add_argument("--service", action="append", required=True)
    parser.add_argument("--log-group", required=True)
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--region", required=True)
    args = parser.parse_args()
    summary = capture(args.cluster, args.service, args.log_group, args.output_dir, args.region)
    return 0 if summary["complete"] else 1


if __name__ == "__main__":
    raise SystemExit(main())

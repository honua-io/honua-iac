#!/usr/bin/env python3
"""Require the applicable named Honua post-apply cases, not just a green test process."""

import os
from pathlib import Path
import sys
import xml.etree.ElementTree as ET

CLASS = "Honua.Server.Tests.Cloud.CloudDeploymentValidationTests"
BASE = {
    "PublicDeploymentEndpoints_AreHealthy",
    "DeployPreflight_ReflectsExpectedEnvironmentState",
    "AdminControlPlaneEndpoints_AreAvailableInCloudDeployment",
}
PLAN = "DeployPlanEndpoint_ReturnsPlan_WhenTargetConfigured_OrNotFoundContract_WhenNoTargetConfigured"
MUTATION = "CloudStagedImport_CompletesAndPublishedLayerBecomesPublicMetadata_WhenMutationChecksAreEnabled"
PROMOTE = "DeployOperation_CanPromote_WhenLiveExecutionIsEnabled"
ROLLBACK = "DeployOperation_CanRollback_WhenRollbackValidationIsEnabled"


def required_cases(env):
    required = set(BASE)
    for flag, case in (("EXPECT_DEPLOY_PLAN_SUPPORT", PLAN), ("EXPECT_MUTATION_SUPPORT", MUTATION)):
        value = env.get("HONUA_CLOUD_TEST_" + flag, "true").lower()
        if value not in ("true", "false"):
            raise ValueError(f"Invalid boolean for {flag}")
        if value == "true":
            required.add(case)
    promote = env.get("HONUA_CLOUD_TEST_EXECUTE_DEPLOY_OPERATION", "false").lower()
    rollback = env.get("HONUA_CLOUD_TEST_VERIFY_DEPLOY_ROLLBACK", "false").lower()
    if promote not in ("true", "false") or rollback not in ("true", "false"):
        raise ValueError("Invalid live deploy/rollback boolean")
    if rollback == "true" and promote != "true":
        raise ValueError("Rollback validation requires live deploy execution")
    if promote == "true":
        required.add(PROMOTE)
        if rollback == "true":
            required.add(ROLLBACK)
    return required


def verify(path, env):
    tree = ET.parse(path)
    methods = {}
    for unit in tree.iter():
        if unit.tag.rsplit("}", 1)[-1] != "UnitTest":
            continue
        for method in unit:
            if method.tag.rsplit("}", 1)[-1] == "TestMethod" and method.get("className") == CLASS:
                methods[unit.get("id")] = method.get("name")
    observed = {}
    failures = []
    for result in tree.iter():
        if result.tag.rsplit("}", 1)[-1] != "UnitTestResult":
            continue
        outcome = result.get("outcome")
        if outcome not in ("Passed", "NotExecuted"):
            failures.append(f"{result.get('testName')}: {outcome}")
        if result.get("testId") in methods:
            observed.setdefault(methods[result.get("testId")], []).append(outcome)
    required = required_cases(env)
    for name in sorted(required):
        outcomes = observed.get(name, [])
        if outcomes != ["Passed"]:
            failures.append(f"{name}: expected one Passed result, observed {outcomes or 'missing'}")
    if failures:
        raise ValueError("\n".join(failures))
    print(f"Post-apply required cases: {len(required)}/{len(required)} passed")
    for name in sorted(required):
        print(f"  PASS {name}")
    return required


if __name__ == "__main__":
    try:
        verify(Path(sys.argv[1]), os.environ)
    except (IndexError, OSError, ET.ParseError, ValueError) as error:
        print(f"Post-apply evidence rejected: {error}", file=sys.stderr)
        sys.exit(1)

#!/usr/bin/env python3
"""Credential-free caller and named-evidence contract checks; no cloud or dotnet."""

import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("evidence", HERE / "assert-platform-validation.py")
evidence = importlib.util.module_from_spec(spec)
spec.loader.exec_module(evidence)


def receipt(path, outcomes):
    root = ET.Element("TestRun", xmlns="http://microsoft.com/schemas/VisualStudio/TeamTest/2010")
    definitions = ET.SubElement(root, "TestDefinitions")
    results = ET.SubElement(root, "Results")
    for number, (name, outcome) in enumerate(outcomes.items()):
        unit = ET.SubElement(definitions, "UnitTest", id=str(number))
        ET.SubElement(unit, "TestMethod", className=evidence.CLASS, name=name)
        # A humanized display name must not prevent matching the real method identity.
        ET.SubElement(results, "UnitTestResult", testId=str(number), testName=name.replace("_", " "), outcome=outcome)
    ET.ElementTree(root).write(path)


class PostApplyContractTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / "server checkout"
        (self.root / "scripts/cloud").mkdir(parents=True)
        (self.root / "scripts/ci").mkdir()
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        self.trx = Path(self.temp.name) / "input.trx"
        self.outcomes = {name: "Passed" for name in evidence.BASE | {evidence.PLAN, evidence.MUTATION}}
        self.env = {key: value for key, value in os.environ.items() if not key.startswith("HONUA_")}
        self.env.update(INPUT_TRX=str(self.trx), INVOCATIONS=str(Path(self.temp.name) / "invocations"))
        self.runner = self.root / "scripts/cloud/run-cloud-post-apply-validation.sh"
        self.runner.write_text('''#!/usr/bin/env bash
set -euo pipefail
printf '%s|%s|%s|%s\n' "$PWD" "$HONUA_CLOUD_TEST_BASE_URL" "${HONUA_CLOUD_TEST_EXPECT_DEPLOY_PLAN_SUPPORT:-}" "$*" >> "$INVOCATIONS"
cp "$INPUT_TRX" "$HONUA_CLOUD_TEST_RESULTS_DIR/cloud-post-apply-validation.trx"
exit "${RUNNER_EXIT:-0}"
''')
        # The server counts checker is independently tested in its owning repository.
        # Verify that the cross-repo caller invokes it and respects a rejecting exit.
        (self.root / "scripts/ci/assert-trx-executed.py").write_text(
            'import os,sys\nfrom pathlib import Path\n'
            'with open(os.environ["INVOCATIONS"], "a") as f: f.write("counts-check\\n")\n'
            'assert Path(sys.argv[sys.argv.index("--trx")+1]).is_file()\n'
            'sys.exit(int(os.environ.get("COUNTS_EXIT", "0")))\n')

    def call(self, platform="aws-ecs", **overrides):
        receipt(self.trx, self.outcomes)
        env = self.env | {"HONUA_PLATFORM_VALIDATION_SCRIPT": str(self.runner)} | overrides
        return subprocess.run(
            ["bash", "-c", 'set -euo pipefail; source "$1"; run_honua_platform_post_apply_validation https://cert.example "$2"',
             "contract", str(HERE / "platform-post-apply-validation.sh"), platform],
            env=env, text=True, capture_output=True)

    def test_canonical_nested_runner_and_named_five_cases(self):
        result = self.call()
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertIn("5/5 passed", result.stdout)
        calls = Path(self.env["INVOCATIONS"]).read_text()
        self.assertIn(str(self.root) + "|https://cert.example", calls)
        self.assertIn("counts-check", calls)

    def test_missing_or_skipped_mutation_cannot_hide_behind_other_passes(self):
        for outcome in (None, "NotExecuted", "Failed"):
            with self.subTest(outcome=outcome):
                self.outcomes = {name: "Passed" for name in evidence.BASE | {evidence.PLAN, "UnrelatedPass"}}
                if outcome:
                    self.outcomes[evidence.MUTATION] = outcome
                result = self.call()
                self.assertNotEqual(0, result.returncode)
                self.assertIn(evidence.MUTATION, result.stderr)

    def test_azure_explicit_unsupported_flags_use_same_runner(self):
        self.outcomes = {name: "Passed" for name in evidence.BASE}
        result = self.call("azure-functions", HONUA_PLATFORM_VALIDATION_EXPECT_DEPLOY_PLAN_SUPPORT="false")
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("3/3 passed", result.stdout)
        self.assertIn("|false|", Path(self.env["INVOCATIONS"]).read_text())

    def test_unsupported_profile_does_not_waive_public_or_admin_serving(self):
        self.outcomes = {evidence.PLAN: "Passed", evidence.MUTATION: "Passed", "Other": "Passed"}
        result = self.call("aws-lambda")
        self.assertNotEqual(0, result.returncode)
        self.assertIn("PublicDeploymentEndpoints_AreHealthy", result.stderr)

    def test_live_upgrade_requires_promote_and_rollback_cases(self):
        result = self.call(HONUA_PLATFORM_VALIDATION_EXECUTE_DEPLOY_OPERATION="true",
                           HONUA_PLATFORM_VALIDATION_VERIFY_DEPLOY_ROLLBACK="true")
        self.assertNotEqual(0, result.returncode)
        self.assertIn(evidence.PROMOTE, result.stderr)
        self.assertIn(evidence.ROLLBACK, result.stderr)
        self.outcomes.update({evidence.PROMOTE: "Passed", evidence.ROLLBACK: "Passed"})
        result = self.call(HONUA_PLATFORM_VALIDATION_EXECUTE_DEPLOY_OPERATION="true",
                           HONUA_PLATFORM_VALIDATION_VERIFY_DEPLOY_ROLLBACK="true")
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("7/7 passed", result.stdout)

    def test_runner_and_counts_failures_propagate(self):
        for variable in ("RUNNER_EXIT", "COUNTS_EXIT"):
            with self.subTest(variable=variable):
                result = self.call(**{variable: "19"})
                self.assertEqual(19, result.returncode, result.stderr)

    def test_rollback_without_live_execution_is_not_a_waiver(self):
        result = self.call(HONUA_PLATFORM_VALIDATION_VERIFY_DEPLOY_ROLLBACK="true")
        self.assertNotEqual(0, result.returncode)
        self.assertIn("Rollback validation requires live deploy execution", result.stderr)

    def test_missing_runner_fails_before_any_invocation(self):
        result = self.call(HONUA_PLATFORM_VALIDATION_SCRIPT=str(self.root / "scripts/old.sh"))
        self.assertNotEqual(0, result.returncode)
        self.assertFalse(Path(self.env["INVOCATIONS"]).exists())

    def test_each_invocation_uses_fresh_evidence(self):
        self.assertEqual(0, self.call().returncode)
        self.runner.write_text("#!/usr/bin/env bash\nexit 0\n")
        result = self.call()
        self.assertNotEqual(0, result.returncode, "prior passing TRX must not satisfy a no-op rerun")


if __name__ == "__main__":
    unittest.main()

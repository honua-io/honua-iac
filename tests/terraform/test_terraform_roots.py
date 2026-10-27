#!/usr/bin/env python3
"""Refusal rules of scripts/check-terraform-roots.py against throwaway git repos (honua-iac#320)."""

from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("check_terraform_roots", ROOT / "scripts" / "check-terraform-roots.py")
roots = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = roots
spec.loader.exec_module(roots)

PROVIDER = 'provider "aws" {\n  region = "us-east-1"\n}\n'
EXAMPLE = 'terraform {\n  backend "s3" {\n    bucket = "REPLACE_WITH_STATE_BUCKET_NAME"\n    key    = "bootstrap/x/terraform.tfstate"\n  }\n}\n'
GITIGNORE = "**/*.tfstate\n**/*.tfstate.*\ninfrastructure/terraform/**/backend.tf\n"


class Fixture:
    def __init__(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = Path(self.tmp.name)
        subprocess.run(["git", "init", "-q", str(self.repo)], check=True)
        self.write(".gitignore", GITIGNORE)
        self.write("infrastructure/terraform/terraform-roots.json", json.dumps({"local_state_allowed": {}}))
        self.write("infrastructure/terraform/bootstrap/good/main.tf", PROVIDER)
        self.write("infrastructure/terraform/bootstrap/good/backend.tf.example", EXAMPLE)
        self.write("infrastructure/terraform/modules/m/main.tf", 'resource "null_resource" "x" {}\n')

    def write(self, path: str, text: str) -> None:
        target = self.repo / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text)

    def allow(self, root: str, reason: str = "operator template") -> None:
        self.write("infrastructure/terraform/terraform-roots.json", json.dumps({"local_state_allowed": {root: reason}}))

    def check(self) -> list[str]:
        subprocess.run(["git", "-C", str(self.repo), "add", "-A", "-f"], check=True)
        return roots.check(self.repo)

    def close(self):
        self.tmp.cleanup()


class TerraformRootStateTests(unittest.TestCase):
    def setUp(self):
        self.f = Fixture()

    def tearDown(self):
        self.f.close()

    def test_good_tree_passes(self):
        self.assertEqual(self.f.check(), [])

    def test_modules_are_not_roots(self):
        self.assertEqual(self.f.check(), [])
        self.assertNotIn("infrastructure/terraform/modules/m", roots.discover_roots(self.f.repo))

    def test_root_without_backend_example_is_refused(self):
        self.f.write("infrastructure/terraform/internal/router/main.tf", PROVIDER)
        self.assertTrue(any("internal/router: no backend.tf.example" in m for m in self.f.check()))

    def test_tfvars_example_makes_a_root(self):
        self.f.write("infrastructure/terraform/components/c/main.tf", 'variable "x" {}\n')
        self.f.write("infrastructure/terraform/components/c/terraform.tfvars.example", 'x = 1\n')
        self.assertTrue(any("components/c: no backend.tf.example" in m for m in self.f.check()))

    def test_listed_local_root_passes_and_needs_a_reason(self):
        self.f.write("infrastructure/terraform/examples/azure/main.tf", PROVIDER)
        self.f.allow("infrastructure/terraform/examples/azure")
        self.assertEqual(self.f.check(), [])
        self.f.allow("infrastructure/terraform/examples/azure", " ")
        self.assertTrue(any("needs a reason" in m for m in self.f.check()))

    def test_stale_listing_is_refused(self):
        self.f.allow("infrastructure/terraform/bootstrap/good")
        self.assertTrue(any("stale" in m for m in self.f.check()))

    def test_listing_a_non_root_is_refused(self):
        self.f.allow("infrastructure/terraform/bootstrap/ghost")
        self.assertTrue(any("not a Terraform root" in m for m in self.f.check()))

    def test_example_without_remote_backend_is_refused(self):
        self.f.write("infrastructure/terraform/bootstrap/good/backend.tf.example", 'terraform {\n  # backend "s3" {}\n  backend "local" {}\n}\n')
        self.assertTrue(any("no active remote backend" in m for m in self.f.check()))

    def test_tracked_backend_block_is_refused(self):
        self.f.write("infrastructure/terraform/bootstrap/good/versions.tf", 'terraform {\n  backend "s3" {}\n}\n')
        self.assertTrue(any("declares a backend in a tracked file" in m for m in self.f.check()))

    def test_commented_backend_block_is_fine(self):
        self.f.write("infrastructure/terraform/bootstrap/good/versions.tf", 'terraform {\n  # backend "s3" {}\n}\n')
        self.assertEqual(self.f.check(), [])

    def test_committed_state_is_refused(self):
        self.f.write("infrastructure/terraform/bootstrap/good/terraform.tfstate", "{}")
        self.f.write("docs/old/terraform.tfstate.backup", "{}")
        failures = self.f.check()
        self.assertTrue(any("bootstrap/good/terraform.tfstate is committed" in m for m in failures))
        self.assertTrue(any("terraform.tfstate.backup is committed" in m for m in failures))

    def test_unignored_state_or_backend_is_refused(self):
        self.f.write(".gitignore", "")
        failures = self.f.check()
        self.assertTrue(any("terraform.tfstate is not gitignored" in m for m in failures))
        self.assertTrue(any("backend.tf is not gitignored" in m for m in failures))

    def test_this_repository_passes(self):
        self.assertEqual(roots.check(ROOT), [])


if __name__ == "__main__":
    unittest.main()

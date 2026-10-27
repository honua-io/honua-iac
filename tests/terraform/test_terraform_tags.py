#!/usr/bin/env python3
"""Tag resolution rules of scripts/check-terraform-tags.py (honua-iac#320)."""

from __future__ import annotations

import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("check_terraform_tags", ROOT / "scripts" / "check-terraform-tags.py")
tags = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = tags
spec.loader.exec_module(tags)

LOCALS = """
locals {
  base = {
    ManagedBy = "terraform"
    Project   = "honua"
  }
  common_tags = merge(local.base, {
    Owner = "honua-platform"
  })
  partial = {
    ManagedBy = "terraform"
  }
}
"""


def resource(tags_line: str) -> str:
    return f'resource "aws_iam_role" "r" {{\n  name = "x"\n{tags_line}\n}}\n'


def expression(text: str) -> str | None:
    _, body, _ = next(tags.blocks(text, r'^resource\s+"(aws_[a-z0-9_]+)"\s+"([^"]+)"\s*\{'))
    return tags.tags_expression(body)


class TagResolution(unittest.TestCase):
    locals_ = tags.local_maps(tags.strip_comments(LOCALS))

    def test_literal_tags_with_both_keys(self):
        expr = expression(resource('  tags = { ManagedBy = "terraform", Owner = "x" }'))
        self.assertTrue(tags.covered(expr, {}))

    def test_literal_tags_with_one_key(self):
        expr = expression(resource('  tags = { ManagedBy = "terraform" }'))
        self.assertFalse(tags.covered(expr, {}))

    def test_local_map_resolved_through_merge(self):
        self.assertTrue(tags.covered(expression(resource("  tags = local.common_tags")), self.locals_))

    def test_partial_local_is_not_enough(self):
        self.assertFalse(tags.covered(expression(resource("  tags = local.partial")), self.locals_))

    def test_merge_of_partial_local_and_literal_owner(self):
        expr = expression(resource('  tags = merge(local.partial, {\n    Owner = "x"\n  })'))
        self.assertTrue(tags.covered(expr, self.locals_))

    def test_missing_tags_argument(self):
        self.assertIsNone(expression(resource("")))

    def test_key_names_must_be_keys_not_values(self):
        expr = expression(resource('  tags = { Purpose = "ManagedBy Owner" }'))
        self.assertFalse(tags.covered(expr, {}))

    def test_default_tags_detection(self):
        provider = 'provider "aws" {\n  default_tags {\n    tags = { ManagedBy = "terraform", Owner = "x" }\n  }\n}\n'
        body = next(tags.blocks(provider, r'^provider\s+"aws"\s*\{'))[1]
        self.assertTrue(any(tags.has_keys(dt) for _, dt, _ in tags.blocks(body, r'^\s*default_tags\s*\{')))

    def test_default_tags_through_a_local(self):
        provider = 'provider "aws" {\n  default_tags {\n    tags = local.common_tags\n  }\n}\n'
        body = next(tags.blocks(provider, r'^provider\s+"aws"\s*\{'))[1]
        self.assertTrue(any(tags.covered(dt, self.locals_) for _, dt, _ in tags.blocks(body, r'^\s*default_tags\s*\{')))

    def test_comments_do_not_count(self):
        expr = expression(tags.strip_comments(resource('  tags = { ManagedBy = "t" } # Owner = "x"')))
        self.assertFalse(tags.covered(expr, {}))


class ScanRoots(unittest.TestCase):
    """scan() over a throwaway tree: provider default_tags resolved through locals."""

    def scan(self, provider_tags: str):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            root = repo / "infrastructure" / "terraform" / "bootstrap" / "x"
            root.mkdir(parents=True)
            (root / "main.tf").write_text(
                LOCALS
                + f'provider "aws" {{\n  default_tags {{\n    tags = {provider_tags}\n  }}\n}}\n'
                + 'resource "aws_iam_role" "r" {\n  name = "x"\n}\n'
            )
            saved = tags.REPO, tags.TERRAFORM
            tags.REPO, tags.TERRAFORM = repo, repo / "infrastructure" / "terraform"
            try:
                return tags.scan({"aws_iam_role"})
            finally:
                tags.REPO, tags.TERRAFORM = saved

    def test_default_tags_from_a_local_cover_untagged_resources(self):
        findings, summary = self.scan("local.common_tags")
        self.assertEqual(findings, [])
        self.assertTrue(summary[0][1], "provider default_tags through local.common_tags must count as covered")

    def test_default_tags_from_a_partial_local_do_not(self):
        findings, _ = self.scan("local.partial")
        self.assertEqual(len(findings), 1)


if __name__ == "__main__":
    unittest.main()

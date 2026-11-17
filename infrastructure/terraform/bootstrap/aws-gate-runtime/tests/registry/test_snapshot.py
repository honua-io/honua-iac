"""Nested template coverage is explicit and pinned to the same source commit."""
import unittest
from unittest.mock import patch
from snapshot import read_templates


class NestedTests(unittest.TestCase):
    def read(self, sources, manifest):
        def git_show(command):
            return sources[command[-1].split(":", 1)[1]].encode()
        with patch("snapshot.subprocess.check_output", side_effect=git_show):
            return read_templates("unused", "commit", manifest)

    def test_recursively_includes_every_nested_resource(self):
        sources = {"root.yaml": "Resources: {Child: {Type: 'AWS::CloudFormation::Stack'}}",
                   "child.yaml": "Resources: {Queue: {Type: 'AWS::SQS::Queue'}}"}
        templates = self.read(sources, {"root": "root.yaml", "nested": {"root.yaml#Child": "child.yaml"}})
        self.assertEqual(["root.yaml", "child.yaml"], [t["path"] for t in templates])

    def test_unmapped_nested_template_fails(self):
        with self.assertRaises(ValueError):
            self.read({"root.yaml": "Resources: {Child: {Type: 'AWS::CloudFormation::Stack'}}"},
                      {"root": "root.yaml", "nested": {}})

    def test_cycle_fails(self):
        with self.assertRaises(ValueError):
            self.read({"root.yaml": "Resources: {Child: {Type: 'AWS::CloudFormation::Stack'}}"},
                      {"root": "root.yaml", "nested": {"root.yaml#Child": "root.yaml"}})

    def test_unused_mapping_fails(self):
        with self.assertRaises(ValueError):
            self.read({"root.yaml": "Resources: {}"},
                      {"root": "root.yaml", "nested": {"root.yaml#Missing": "missing.yaml"}})


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""Offline admission controls for immutable registry module inputs."""
import hashlib
import json
import tempfile
import unittest
from pathlib import Path

import verify_reviewed_modules as subject


class ReviewedModules(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.root = self.base / "root"
        self.cache = self.root / ".terraform/modules"
        self.cache.mkdir(parents=True)
        self.manifest = self.base / "manifest.json"
        modules = []
        index = [{"Key": "", "Source": "", "Dir": "."}]
        for name, source, version in (("vpc", "registry.terraform.io/terraform-aws-modules/vpc/aws", "5.21.0"),
                                      ("rds", "registry.terraform.io/terraform-aws-modules/rds/aws", "6.13.1")):
            directory = self.cache / name
            directory.mkdir()
            data = ("reviewed " + name + "\n").encode()
            file = directory / "main.tf"
            file.write_bytes(data)
            file.chmod(0o664)
            modules.append({"source": source, "version": version,
                            "files": {"main.tf": {"mode": 0o644, "size": len(data),
                                                  "sha256": hashlib.sha256(data).hexdigest()}}})
            index.append({"Key": "honua." + name, "Source": source, "Version": version,
                          "Dir": ".terraform/modules/" + name})
            if name == "rds":
                for child in sorted(subject.RDS_CHILDREN):
                    nested = directory / "modules" / child
                    nested.mkdir(parents=True)
                    content = ("reviewed " + child + "\n").encode()
                    (nested / "main.tf").write_bytes(content)
                    modules[-1]["files"]["modules/" + child + "/main.tf"] = {
                        "mode": 0o644, "size": len(content),
                        "sha256": hashlib.sha256(content).hexdigest()}
                    index.append({"Key": "honua.rds." + child,
                                  "Source": "./modules/" + child,
                                  "Dir": ".terraform/modules/rds/modules/" + child})
        for key, source in subject.LOCAL_SOURCES.items():
            index.append({"Key": key, "Source": source, "Dir": source})
        self.manifest.write_text(json.dumps({"schema": "honua.aws-cert-reviewed-modules/v1", "modules": modules}))
        (self.cache / "modules.json").write_text(json.dumps({"Modules": index}))

    def verify(self):
        return subject.verify(self.root, self.manifest)

    def test_exact_bytes_then_normalize_mode(self):
        self.assertEqual(self.verify()["status"], "verified")
        for name in ("vpc", "rds"):
            self.assertEqual((self.cache / name / "main.tf").stat().st_mode & 0o777, 0o644)

    def test_unreviewed_and_changed_files_refused(self):
        (self.cache / "vpc/extra.tf").write_text("unreviewed")
        with self.assertRaises(subject.Refused):
            self.verify()
        (self.cache / "vpc/extra.tf").unlink()
        (self.cache / "vpc/main.tf").write_text("changed")
        with self.assertRaises(subject.Refused):
            self.verify()

    def test_version_and_link_refused(self):
        index_path = self.cache / "modules.json"
        index = json.loads(index_path.read_text())
        index["Modules"][0]["Version"] = "5.22.0"
        index_path.write_text(json.dumps(index))
        with self.assertRaises(subject.Refused):
            self.verify()
        index["Modules"][0]["Version"] = "5.21.0"
        index_path.write_text(json.dumps(index))
        (self.cache / "vpc/main.tf").unlink()
        (self.cache / "vpc/main.tf").symlink_to(self.cache / "rds/main.tf")
        with self.assertRaises(subject.Refused):
            self.verify()

    def test_unreviewed_registry_source_refused(self):
        index_path = self.cache / "modules.json"
        index = json.loads(index_path.read_text())
        index["Modules"].append({"Key": "honua.extra", "Source": "registry.terraform.io/example/extra/aws",
                                 "Version": "1.0.0", "Dir": ".terraform/modules/extra"})
        index_path.write_text(json.dumps(index))
        with self.assertRaisesRegex(subject.Refused, "module-unreviewed-source"):
            self.verify()

    def test_relative_source_cannot_redirect_to_cached_copy(self):
        index_path = self.cache / "modules.json"
        index = json.loads(index_path.read_text())
        local = next(item for item in index["Modules"] if item["Key"] == "honua")
        (self.cache / "honua").mkdir()
        (self.cache / "honua/main.tf").write_text("unreviewed local module")
        local["Dir"] = ".terraform/modules/honua"
        index_path.write_text(json.dumps(index))
        with self.assertRaisesRegex(subject.Refused, "local-module-location-invalid"):
            self.verify()

    def test_relative_source_requires_exact_tracked_local_module(self):
        index_path = self.cache / "modules.json"
        index = json.loads(index_path.read_text())
        local = next(item for item in index["Modules"] if item["Key"] == "honua")
        local["Source"] = "../../modules/alternate"
        local["Dir"] = local["Source"]
        index_path.write_text(json.dumps(index))
        with self.assertRaisesRegex(subject.Refused, "module-unreviewed-source"):
            self.verify()

    def test_rds_nested_module_cannot_redirect_to_unreviewed_cache(self):
        index_path = self.cache / "modules.json"
        index = json.loads(index_path.read_text())
        nested = next(item for item in index["Modules"] if item["Key"] == "honua.rds.db_instance")
        (self.cache / "copied-module").mkdir()
        (self.cache / "copied-module/main.tf").write_text("unreviewed")
        nested["Dir"] = ".terraform/modules/copied-module"
        index_path.write_text(json.dumps(index))
        with self.assertRaisesRegex(subject.Refused, "nested-module-location-invalid"):
            self.verify()

    def test_empty_source_cannot_add_cached_module(self):
        index_path = self.cache / "modules.json"
        index = json.loads(index_path.read_text())
        index["Modules"].append({"Key": "honua.unreviewed", "Source": "",
                                 "Dir": ".terraform/modules/copied-module"})
        index_path.write_text(json.dumps(index))
        with self.assertRaises(subject.Refused):
            self.verify()


if __name__ == "__main__":
    unittest.main()

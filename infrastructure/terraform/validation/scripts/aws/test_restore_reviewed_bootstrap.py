#!/usr/bin/env python3
"""Offline exact ZIP restoration controls."""
import hashlib
import json
import tempfile
import unittest
import zipfile
from pathlib import Path

import restore_reviewed_bootstrap as subject


class BootstrapRestore(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.root = self.base / "root"
        self.target = self.root / "postgis-bootstrap"
        self.target.mkdir(parents=True)
        self.handler = b"def handler(event, context): return {}\n"
        (self.target / "handler.py").write_bytes(self.handler)
        self.archive = self.base / "approved.zip"
        with zipfile.ZipFile(self.archive, "w", compression=zipfile.ZIP_DEFLATED) as output:
            for name, content in (("handler.py", self.handler), ("dependency.py", b"VERSION = 1\n")):
                info = zipfile.ZipInfo(name)
                info.external_attr = (0o100644 << 16)
                output.writestr(info, content)
        self.manifest = self.base / "manifest.json"
        self.manifest.write_text(json.dumps({"schema": "honua.aws-cert-reviewed-bootstrap/v1",
            "size": self.archive.stat().st_size,
            "zipSha256": hashlib.sha256(self.archive.read_bytes()).hexdigest(),
            "entryCount": 2, "handlerSha256": hashlib.sha256(self.handler).hexdigest()}))

    def test_exact_restoration(self):
        self.assertEqual(subject.restore(self.root, self.archive, self.manifest)["status"], "restored")
        self.assertEqual((self.target / "bootstrap.zip").read_bytes(), self.archive.read_bytes())
        self.assertEqual((self.target / "build/handler.py").read_bytes(), self.handler)

    def test_changed_zip_and_handler_refused(self):
        self.archive.write_bytes(self.archive.read_bytes() + b"changed")
        with self.assertRaisesRegex(ValueError, "archive-mismatch"):
            subject.restore(self.root, self.archive, self.manifest)
        self.archive.write_bytes(self.archive.read_bytes()[:-7])
        (self.target / "handler.py").write_text("changed")
        with self.assertRaisesRegex(ValueError, "handler-mismatch"):
            subject.restore(self.root, self.archive, self.manifest)


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""Restore the exact reviewed deployed bootstrap ZIP as transient plan input."""
import argparse
import hashlib
import json
import os
import shutil
import stat
import sys
import tempfile
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import standing_cert_plan as producer


def require(value, reason):
    if not value:
        raise ValueError(reason)


def restore(root, archive, manifest):
    root = Path(root)
    archive = Path(archive)
    metadata = json.loads(Path(manifest).read_bytes())
    require(metadata["schema"] == "honua.aws-cert-reviewed-bootstrap/v1", "bootstrap-manifest-invalid")
    content = archive.read_bytes()
    require(len(content) == metadata["size"] <= producer.MAX_ARTIFACT_BYTES
            and hashlib.sha256(content).hexdigest() == metadata["zipSha256"], "bootstrap-archive-mismatch")
    target = root / "postgis-bootstrap"
    handler = target / "handler.py"
    require(target.is_dir() and not target.is_symlink() and handler.is_file() and not handler.is_symlink()
            and hashlib.sha256(handler.read_bytes()).hexdigest() == metadata["handlerSha256"],
            "bootstrap-handler-mismatch")
    build = target / "build"
    output = target / "bootstrap.zip"
    require(not build.exists() and not build.is_symlink() and not output.exists() and not output.is_symlink(),
            "bootstrap-destination-occupied")
    inventory = producer.bootstrap_zip_inventory(content)
    require(len(inventory) == metadata["entryCount"] and "handler.py" in inventory
            and inventory["handler.py"]["sha256"] == metadata["handlerSha256"],
            "bootstrap-entries-invalid")
    staged = Path(tempfile.mkdtemp(prefix=".bootstrap-reviewed-", dir=target))
    try:
        with zipfile.ZipFile(archive) as source:
            for member in source.infolist():
                require(not member.is_dir() and stat.S_IFMT(member.external_attr >> 16) in (0, stat.S_IFREG)
                        and stat.S_IMODE(member.external_attr >> 16) == 0o644,
                        "bootstrap-entry-mode-invalid")
                destination = staged / member.filename
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes(source.read(member))
                destination.chmod(0o644)
        for parent, children, _ in os.walk(staged):
            for name in children:
                (Path(parent) / name).chmod(0o755)
        staged.chmod(0o755)
        staged.rename(build)
        with output.open("xb") as destination:
            destination.write(content)
        output.chmod(0o600)
        require(producer.bootstrap_inventory(root) == inventory
                and hashlib.sha256(output.read_bytes()).hexdigest() == metadata["zipSha256"],
                "bootstrap-restore-mismatch")
    except BaseException:
        shutil.rmtree(staged, ignore_errors=True)
        shutil.rmtree(build, ignore_errors=True)
        output.unlink(missing_ok=True)
        raise
    return {"schema": metadata["schema"], "status": "restored",
            "zipSha256": metadata["zipSha256"]}


if __name__ == "__main__":
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True, type=Path)
    parser.add_argument("--archive", required=True, type=Path)
    parser.add_argument("--manifest", required=True, type=Path)
    args = parser.parse_args()
    try:
        print(json.dumps(restore(args.root, args.archive, args.manifest), sort_keys=True))
    except (ValueError, OSError, KeyError, TypeError, zipfile.BadZipFile, producer.Refused):
        print('{"status":"refused"}')
        sys.exit(3)

#!/usr/bin/env python3
"""Admit only the reviewed aws-cert registry modules after Terraform init.

Terraform's version constraints alone do not identify the bytes it downloads.
This check binds every regular file to the reviewed upstream commit inventory.
"""
import argparse
import hashlib
import json
import os
import stat
import sys
from pathlib import Path

SOURCES = {"registry.terraform.io/terraform-aws-modules/vpc/aws",
           "registry.terraform.io/terraform-aws-modules/rds/aws"}
MAX_FILES = 512
MAX_BYTES = 32 * 1024 * 1024


class Refused(Exception):
    pass


def require(value, reason):
    if not value:
        raise Refused(reason)


def regular_tree(directory, expected):
    require(directory.is_dir() and not directory.is_symlink(), "module-directory-invalid")
    actual = set()
    total = 0
    for parent, children, names in os.walk(directory, followlinks=False):
        for name in children:
            path = Path(parent) / name
            info = path.lstat()
            require(stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid(), "module-entry-invalid")
        for name in names:
            path = Path(parent) / name
            info = path.lstat()
            require(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid()
                    and info.st_size <= MAX_BYTES, "module-entry-invalid")
            relative = path.relative_to(directory).as_posix()
            require(relative in expected and relative not in actual, "module-unreviewed-file")
            descriptor = expected[relative]
            content = path.read_bytes()
            total += len(content)
            require(len(actual) < MAX_FILES and total <= MAX_BYTES
                    and len(content) == info.st_size == descriptor["size"]
                    and hashlib.sha256(content).hexdigest() == descriptor["sha256"]
                    and descriptor["mode"] == 0o644, "module-content-mismatch")
            # GitHub's immutable commit archive currently carries 0664 modes.
            # Normalize only after authenticating content, before admitting it.
            path.chmod(0o644)
            actual.add(relative)
    require(actual == set(expected), "module-files-incomplete")
    for parent, children, _ in os.walk(directory, followlinks=False):
        for name in children:
            (Path(parent) / name).chmod(0o755)
    directory.chmod(0o755)


def verify(root, manifest):
    root = Path(root)
    cache = root / ".terraform/modules"
    require(cache.is_dir() and not cache.is_symlink(), "module-cache-invalid")
    index_path = cache / "modules.json"
    require(index_path.is_file() and not index_path.is_symlink(), "module-index-invalid")
    index = json.loads(index_path.read_bytes())
    require(isinstance(index.get("Modules"), list), "module-index-invalid")
    reviewed = json.loads(Path(manifest).read_bytes())
    require(reviewed.get("schema") == "honua.aws-cert-reviewed-modules/v1"
            and len(reviewed.get("modules", [])) == 2, "reviewed-manifest-invalid")
    by_source = {item["source"]: item for item in reviewed["modules"]}
    require(set(by_source) == SOURCES, "reviewed-manifest-invalid")
    found = set()
    for item in index["Modules"]:
        source = item.get("Source")
        if item.get("Dir", "").startswith(".terraform/modules/") and source:
            require(source in SOURCES or source.startswith(("./", "../")),
                    "module-unreviewed-source")
        if source not in SOURCES:
            continue
        require(source not in found and item.get("Version") == by_source[source]["version"],
                "module-version-or-source-mismatch")
        location = Path(item.get("Dir", ""))
        require(not location.is_absolute() and ".." not in location.parts
                and len(location.parts) == 3 and location.parts[:2] == (".terraform", "modules"),
                "module-location-invalid")
        directory = root / location
        regular_tree(directory, by_source[source]["files"])
        found.add(source)
    require(found == SOURCES, "module-missing")
    return {"schema": reviewed["schema"], "status": "verified",
            "manifestSha256": hashlib.sha256(Path(manifest).read_bytes()).hexdigest(),
            "versions": {source: by_source[source]["version"] for source in sorted(SOURCES)}}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True, type=Path)
    parser.add_argument("--manifest", required=True, type=Path)
    args = parser.parse_args()
    try:
        print(json.dumps(verify(args.root, args.manifest), sort_keys=True))
    except (Refused, OSError, ValueError, TypeError, KeyError):
        print('{"status":"refused"}')
        sys.exit(3)

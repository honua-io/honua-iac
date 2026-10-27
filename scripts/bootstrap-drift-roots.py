#!/usr/bin/env python3
"""Read infrastructure/terraform/bootstrap/drift-roots.json for the bootstrap drift plan.

Usage:
  scripts/bootstrap-drift-roots.py --check                 # every bootstrap root is listed, nothing else
  scripts/bootstrap-drift-roots.py --matrix                # JSON matrix: [{"root", "applied"}]
  scripts/bootstrap-drift-roots.py --get ROOT KEY          # one field (JSON unless a string)
  scripts/bootstrap-drift-roots.py --tfvars ROOT ACCOUNT BUCKET   # the root's inputs as tfvars JSON
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
BOOTSTRAP = REPO / "infrastructure" / "terraform" / "bootstrap"
MANIFEST = BOOTSTRAP / "drift-roots.json"


def load_manifest(path: Path = MANIFEST) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def root_dirs(base: Path = BOOTSTRAP) -> list[str]:
    return sorted(p.name for p in base.iterdir() if p.is_dir() and any(p.glob("*.tf")))


def problems(manifest: dict, base: Path = BOOTSTRAP) -> list[str]:
    found = []
    present = root_dirs(base)
    for name in present:
        if name not in manifest["roots"]:
            found.append(f"bootstrap/{name} is a Terraform root but drift-roots.json does not list it")
    for name, entry in manifest["roots"].items():
        if name not in present:
            found.append(f"drift-roots.json lists {name}, which is not a root under bootstrap/")
        if not entry.get("state_key", "").startswith(manifest["state_key_prefix"]):
            found.append(f"{name}: state_key must sit under {manifest['state_key_prefix']} (the drift role reads only that prefix)")
        if entry.get("applied") and not isinstance(entry.get("vars"), dict):
            found.append(f"{name}: applied roots need a vars object (may be empty)")
    return found


def render(value, account: str, bucket: str):
    if isinstance(value, str):
        return value.replace("{account_id}", account).replace("{state_bucket}", bucket)
    if isinstance(value, list):
        return [render(v, account, bucket) for v in value]
    if isinstance(value, dict):
        return {k: render(v, account, bucket) for k, v in value.items()}
    return value


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--check", action="store_true")
    group.add_argument("--matrix", action="store_true")
    group.add_argument("--get", nargs=2, metavar=("ROOT", "KEY"))
    group.add_argument("--tfvars", nargs=3, metavar=("ROOT", "ACCOUNT", "BUCKET"))
    args = parser.parse_args()
    manifest = load_manifest()

    issues = problems(manifest)
    if issues:
        for issue in issues:
            print(f"::error::{issue}", file=sys.stderr)
        return 1
    if args.check:
        print("drift-roots.json covers: " + ", ".join(root_dirs()))
    elif args.matrix:
        print(json.dumps([{"root": n, "applied": bool(e.get("applied"))} for n, e in sorted(manifest["roots"].items())]))
    elif args.get:
        value = manifest["roots"][args.get[0]].get(args.get[1], "")
        print(value if isinstance(value, str) else json.dumps(value))
    else:
        root, account, bucket = args.tfvars
        if not re.fullmatch(r"[0-9]{12}", account):
            print("ACCOUNT must be a 12-digit AWS account id", file=sys.stderr)
            return 1
        print(json.dumps(render(manifest["roots"][root].get("vars", {}), account, bucket), indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())

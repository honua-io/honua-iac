#!/usr/bin/env python3
"""Every Terraform root keeps remote state; no state file is ever committed (honua-iac#320).

On 2026-10-26/27 two bootstrap roots (aws-validation-reaper, aws-release-cells)
were found applied with no remote state, and internal/gtm-forms-router
documented local state outright. A root whose state lives on one workstation
cannot be planned by anyone else, cannot be drift-checked, and is lost with
the disk. scripts/check-backend-examples.sh already holds the release-qualified
AWS examples to a strict backend contract; this check covers every root.

Rules, static (no credentials, no network):

  1. Every root ships backend.tf.example with an active remote backend block
     (s3, azurerm, gcs, remote or cloud), or is listed in
     infrastructure/terraform/terraform-roots.json `local_state_allowed` with a
     reason. A listed root that ships an example is stale and fails too.
  2. No tracked .tf file under infrastructure/terraform declares a backend:
     AGENTS.md -- the operator copies backend.tf.example to the gitignored
     backend.tf, so the activated form never reaches git.
  3. No state is tracked anywhere in the repository (*.tfstate,
     *.tfstate.backup, terraform.tfstate.d/).
  4. For every root, <root>/terraform.tfstate and <root>/backend.tf are
     gitignored, so `git add -A` cannot commit either.

A root is a directory under infrastructure/terraform (outside modules/) that
configures a provider or ships terraform.tfvars.example.

Usage: scripts/check-terraform-roots.py [--repo PATH]
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

REMOTE_BACKENDS = ("s3", "azurerm", "gcs", "remote", "cloud", "http", "consul", "pg", "kubernetes", "oss", "cos")
TERRAFORM = Path("infrastructure") / "terraform"
MANIFEST = TERRAFORM / "terraform-roots.json"


def uncommented(text: str) -> str:
    out = []
    for line in text.splitlines():
        line = re.sub(r"(#|//).*$", "", line)
        out.append(line)
    return "\n".join(out)


def tracked(repo: Path, *patterns: str) -> list[str]:
    result = subprocess.run(["git", "-C", str(repo), "ls-files", "--", *patterns], capture_output=True, text=True, check=True)
    return [line for line in result.stdout.splitlines() if line]


def ignored(repo: Path, path: str) -> bool:
    return subprocess.run(["git", "-C", str(repo), "check-ignore", "-q", "--no-index", path]).returncode == 0


def discover_roots(repo: Path) -> list[str]:
    roots = set()
    for tf in tracked(repo, f"{TERRAFORM.as_posix()}/*.tf", f"{TERRAFORM.as_posix()}/*terraform.tfvars.example"):
        path = Path(tf)
        if "modules" in path.parts or ".terraform" in path.parts or "tests" in path.parts:
            continue
        if path.name == "terraform.tfvars.example":
            roots.add(path.parent.as_posix())
            continue
        if re.search(r'(?m)^\s*provider\s+"', uncommented((repo / path).read_text(encoding="utf-8"))):
            roots.add(path.parent.as_posix())
    return sorted(roots)


def remote_backend(example: Path) -> str | None:
    match = re.search(r'(?m)^\s*backend\s+"([a-z0-9_]+)"\s*\{', uncommented(example.read_text(encoding="utf-8")))
    return match.group(1) if match else None


def check(repo: Path) -> list[str]:
    failures: list[str] = []
    manifest = json.loads((repo / MANIFEST).read_text(encoding="utf-8"))
    allowed: dict = manifest.get("local_state_allowed", {})
    roots = discover_roots(repo)

    for root in roots:
        example = repo / root / "backend.tf.example"
        if root in allowed:
            if not str(allowed[root]).strip():
                failures.append(f"{root}: local_state_allowed needs a reason")
            if example.exists():
                failures.append(f"{root}: ships backend.tf.example but is still listed in local_state_allowed; remove the stale entry")
            continue
        if not example.exists():
            failures.append(
                f"{root}: no backend.tf.example. Ship one (remote backend, placeholder bucket, exclusive key) "
                f"or list the root in {MANIFEST.as_posix()} local_state_allowed with the reason it never holds shared state"
            )
            continue
        backend = remote_backend(example)
        if backend not in REMOTE_BACKENDS:
            failures.append(f"{root}/backend.tf.example declares no active remote backend (found: {backend or 'none'})")

    for name in allowed:
        if name not in roots:
            failures.append(f"{MANIFEST.as_posix()} lists {name}, which is not a Terraform root")

    for tf in tracked(repo, f"{TERRAFORM.as_posix()}/*.tf"):
        if re.search(r'(?m)^\s*backend\s+"', uncommented((repo / tf).read_text(encoding="utf-8"))):
            failures.append(f"{tf} declares a backend in a tracked file; move it to backend.tf.example (AGENTS.md)")

    for state in tracked(repo, "*.tfstate", "*.tfstate.*", "*terraform.tfstate.d/*"):
        failures.append(f"{state} is committed Terraform state; remove it from git (it holds secrets and lineage)")

    for root in roots:
        for name in ("terraform.tfstate", "terraform.tfstate.backup", "backend.tf"):
            if not ignored(repo, f"{root}/{name}"):
                failures.append(f"{root}/{name} is not gitignored")

    return failures


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    repo = args.repo.resolve()

    failures = check(repo)
    roots = discover_roots(repo)
    for failure in failures:
        print(f"FAIL: {failure}", file=sys.stderr)
    if failures:
        print(f"\n{len(failures)} Terraform root state check(s) failed.", file=sys.stderr)
        return 1
    allowed = json.loads((repo / MANIFEST).read_text(encoding="utf-8")).get("local_state_allowed", {})
    print(f"{len(roots)} roots: {len(roots) - len(allowed)} ship a remote backend example, {len(allowed)} are listed local-only templates.")
    print("No tracked backend block, no committed state, state and backend.tf gitignored everywhere.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

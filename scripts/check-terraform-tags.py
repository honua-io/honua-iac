#!/usr/bin/env python3
"""ManagedBy and Owner tags on every taggable AWS resource (honua-iac#320).

An untagged resource cannot be traced to the IaC that owns it, so drift and
orphan sweeps cannot tell a managed resource from a hand-made one. This check
is static: it reads the .tf files of each AWS root under infrastructure/terraform
(not modules/) and reports every taggable resource that will not carry both keys.

A resource passes when either:
  - every `provider "aws"` block of its root sets default_tags with both
    ManagedBy and Owner (this also covers every resource inside the modules the
    root calls -- the only way module resources are covered), or
  - its own `tags` expression carries both keys, literally or through a
    `local.<name>` maps; keys may come from different pieces of a merge()
    (two levels of locals are resolved).

Taggable types come from the AWS provider schema (resource types with a `tags`
attribute): pass --taggable FILE (a JSON list) or --schema-root DIR (an
initialised root to run `terraform providers schema -json` in). Without
either, a resource counts as taggable when it already has a `tags` argument.

Mode: WARNING. Findings are GitHub ::warning annotations and the exit code is
0, because most existing roots tag ManagedBy but not Owner and adding tags is
an in-place change to live resources. --strict exits 1 on any finding; flip CI
to --strict once the count reaches zero.

Usage: scripts/check-terraform-tags.py [--schema-root DIR | --taggable FILE] [--strict] [--summary FILE]
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
TERRAFORM = REPO / "infrastructure" / "terraform"
REQUIRED = ("ManagedBy", "Owner")


def strip_comments(text: str) -> str:
    return "\n".join(re.sub(r"(#|//).*$", "", line) for line in text.splitlines())


def blocks(text: str, header: str):
    """Yield (match, body, start_line) for each top-level block whose header matches."""
    for match in re.finditer(header, text, re.MULTILINE):
        depth, index = 0, match.end() - 1
        for index in range(match.end() - 1, len(text)):
            if text[index] == "{":
                depth += 1
            elif text[index] == "}":
                depth -= 1
                if depth == 0:
                    break
        yield match, text[match.end() : index], text.count("\n", 0, match.start()) + 1


def has_keys(text: str) -> bool:
    return all(re.search(rf'["\s{{,(]{key}["\s]*=', text) for key in REQUIRED)


def aws_roots() -> list[Path]:
    roots = set()
    for tf in TERRAFORM.rglob("*.tf"):
        rel = tf.relative_to(TERRAFORM).parts
        if rel[0] == "modules" or ".terraform" in rel or "tests" in rel:
            continue
        if re.search(r'(?m)^\s*provider\s+"aws"', strip_comments(tf.read_text(encoding="utf-8"))):
            roots.add(tf.parent)
    return sorted(roots)


def local_maps(text: str) -> dict[str, str]:
    """name -> source text of each local value (top-level entries of locals blocks)."""
    found: dict[str, str] = {}
    for _, body, _ in blocks(text, r'^locals\s*\{'):
        entries = list(re.finditer(r"(?m)^  ([A-Za-z_][A-Za-z0-9_]*)\s*=", body))
        for i, entry in enumerate(entries):
            end = entries[i + 1].start() if i + 1 < len(entries) else len(body)
            found[entry.group(1)] = body[entry.end() : end]
    return found


def tags_expression(body: str) -> str | None:
    match = re.search(r"(?m)^  tags\s*=\s*", body)
    if not match:
        return None
    rest = body[match.end() :]
    depth = 0
    for index, char in enumerate(rest):
        if char in "({[":
            depth += 1
        elif char in ")}]":
            depth -= 1
        elif char == "\n" and depth <= 0:
            return rest[:index]
    return rest


def keys_in(expression: str, locals_: dict[str, str], depth: int = 0) -> set[str]:
    """Required keys an expression sets, literally or through local.<name> maps (two levels)."""
    present = {key for key in REQUIRED if re.search(rf'["\s{{,(]{key}["\s]*=', expression)}
    if depth < 2:
        for name in set(re.findall(r"local\.([A-Za-z_][A-Za-z0-9_]*)", expression)):
            if name in locals_:
                present |= keys_in(locals_[name], locals_, depth + 1)
    return present


def covered(expression: str, locals_: dict[str, str]) -> bool:
    return keys_in(expression, locals_) == set(REQUIRED)


def taggable_types(args) -> set[str] | None:
    if args.taggable:
        return set(json.loads(Path(args.taggable).read_text(encoding="utf-8")))
    if args.schema_root:
        schema = json.loads(subprocess.run(["terraform", f"-chdir={args.schema_root}", "providers", "schema", "-json"],
                                           capture_output=True, text=True, check=True).stdout)
        aws = schema["provider_schemas"]["registry.terraform.io/hashicorp/aws"]["resource_schemas"]
        return {name for name, value in aws.items() if "tags" in value["block"].get("attributes", {})}
    return None


def scan(taggable: set[str] | None):
    findings = []
    summary = []
    for root in aws_roots():
        text = {tf: strip_comments(tf.read_text(encoding="utf-8")) for tf in sorted(root.glob("*.tf"))}
        joined = "\n".join(text.values())
        providers = [body for _, body, _ in blocks(joined, r'^provider\s+"aws"\s*\{')]
        default_ok = bool(providers) and all(
            any(has_keys(dt) for _, dt, _ in blocks(body, r'^\s*default_tags\s*\{')) for body in providers
        )
        locals_ = local_maps(joined)
        missing = []
        total = 0
        for tf, content in text.items():
            for match, body, line in blocks(content, r'^resource\s+"(aws_[a-z0-9_]+)"\s+"([^"]+)"\s*\{'):
                kind = match.group(1)
                expression = tags_expression(body)
                if taggable is not None and kind not in taggable:
                    continue
                if taggable is None and expression is None:
                    continue
                total += 1
                if default_ok or (expression is not None and covered(expression, locals_)):
                    continue
                why = "no tags argument" if expression is None else "its tags name neither key, or only one"
                missing.append((tf, line, f"{kind}.{match.group(2)}", why))
        modules = len(re.findall(r'(?m)^module\s+"', joined))
        rel = root.relative_to(REPO).as_posix()
        summary.append((rel, default_ok, total, len(missing), modules))
        findings.extend((rel, *item) for item in missing)
    return findings, summary


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--taggable")
    parser.add_argument("--schema-root")
    parser.add_argument("--strict", action="store_true")
    parser.add_argument("--summary", help="append a Markdown table here (e.g. $GITHUB_STEP_SUMMARY)")
    args = parser.parse_args()

    findings, summary = scan(taggable_types(args))
    for root, tf, line, address, why in findings:
        level = "error" if args.strict else "warning"
        print(f"::{level} file={tf.relative_to(REPO).as_posix()},line={line}::{address} will not carry ManagedBy and Owner ({why}). "
              f"Set provider default_tags in {root} or tag the resource.")

    table = ["| Root | provider default_tags ManagedBy+Owner | taggable resources | missing | module calls (covered only by default_tags) |", "|---|---|---|---|---|"]
    for root, default_ok, total, missing, modules in summary:
        table.append(f"| `{root}` | {'yes' if default_ok else 'no'} | {total} | {missing} | {modules if not default_ok else 0} |")
    table.append(f"\n{len(findings)} taggable resource(s) without ManagedBy and Owner across {len(summary)} AWS roots"
                 f" ({'strict' if args.strict else 'warning mode'}).")
    print("\n".join(table))
    if args.summary:
        with open(args.summary, "a", encoding="utf-8") as handle:
            handle.write("### ManagedBy / Owner tags\n\n" + "\n".join(table) + "\n")
    return 1 if (args.strict and findings) else 0


if __name__ == "__main__":
    sys.exit(main())

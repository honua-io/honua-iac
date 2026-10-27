#!/usr/bin/env python3
"""Prove a GitHub source archive is exactly one commit's tree before it is attested.

Release locks pin honua-iac as https://github.com/honua-io/honua-iac/archive/<commit>.tar.gz
by the sha256 of the bytes GitHub serves. GitHub generates those bytes, not this
workflow, so they are attested only after this check passes. The check requires:

* the archive's pax global header to carry the commit id (git get-tar-commit-id);
* every member, with its type, mode, link target and content, to equal what
  `git archive <commit>` produces locally, member for member.

gzip framing is not compared (only the gzip stream differs between producers);
everything a consumer extracts is.
"""
from __future__ import annotations

import argparse
import gzip
import hashlib
import io
from pathlib import Path
import subprocess
import sys
import tarfile


class ArchiveMismatch(ValueError):
    pass


def _members(raw_tar: bytes) -> dict[str, tuple]:
    rows: dict[str, tuple] = {}
    with tarfile.open(fileobj=io.BytesIO(raw_tar), mode="r:") as archive:
        for member in archive.getmembers():
            if member.type in (tarfile.XGLTYPE, tarfile.XHDTYPE):
                continue
            content = b""
            if member.isfile():
                extracted = archive.extractfile(member)
                content = extracted.read() if extracted else b""
            rows[member.name.rstrip("/")] = (member.type, member.mode & 0o777, member.linkname,
                                             hashlib.sha256(content).hexdigest())
    return rows


def commit_id(raw_tar: bytes) -> str:
    result = subprocess.run(["git", "get-tar-commit-id"], input=raw_tar[:1024 * 16],
                            capture_output=True, check=False)
    return result.stdout.decode().strip()


def verify(archive: Path, *, repo: Path, commit: str, prefix: str) -> str:
    published = archive.read_bytes()
    try:
        raw = gzip.decompress(published)
    except OSError as exc:
        raise ArchiveMismatch(f"{archive} is not a gzip stream: {exc}") from exc
    found = commit_id(raw)
    if found != commit:
        raise ArchiveMismatch(f"archive pax header names commit {found or 'none'}, expected {commit}")
    expected = subprocess.run(["git", "-C", str(repo), "archive", "--format=tar", f"--prefix={prefix}/", commit],
                              capture_output=True, check=True).stdout
    ours, theirs = _members(expected), _members(raw)
    if ours != theirs:
        missing = sorted(set(ours) - set(theirs))[:5]
        extra = sorted(set(theirs) - set(ours))[:5]
        changed = sorted(name for name in set(ours) & set(theirs) if ours[name] != theirs[name])[:5]
        raise ArchiveMismatch(f"archive tree differs from {commit}: missing={missing} extra={extra} changed={changed}")
    return "sha256:" + hashlib.sha256(published).hexdigest()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--archive", type=Path, required=True)
    parser.add_argument("--repo", type=Path, default=Path("."))
    parser.add_argument("--commit", required=True)
    parser.add_argument("--prefix", required=True, help="top-level directory GitHub uses, <repo>-<commit>")
    args = parser.parse_args(argv)
    try:
        digest = verify(args.archive, repo=args.repo, commit=args.commit, prefix=args.prefix)
    except (ArchiveMismatch, subprocess.CalledProcessError) as exc:
        print(f"::error::{exc}", file=sys.stderr)
        return 1
    print(digest)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

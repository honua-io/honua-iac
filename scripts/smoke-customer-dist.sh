#!/usr/bin/env bash
# Consume the published customer distribution tarball and prove every packaged
# example can `terraform init`.
#
# The repo-root `static-validate` CI job inits/validates the examples in their
# source-repo layout, but the customer tarball ships a DIFFERENT (flat) layout:
# modules/, examples/, bootstrap/, marketplace/ become siblings and maintainer-
# only roots (e.g. examples/aws-cert) are dropped. A packaging bug — such as a
# module source-path rewrite that dangles in the flat layout — breaks
# `terraform init` for the operator even though the source repo validates
# cleanly. This test packages the tarball exactly as shipped, extracts it, and
# runs `terraform init` on each packaged example so that class of regression
# fails CI instead of the customer.
#
# Usage:
#   ./scripts/smoke-customer-dist.sh
#
# Requires: terraform on PATH. Runs `terraform init -backend=false` (no cloud
# credentials or state backend needed). Examples whose module sources are all
# remote (e.g. the git-source registry-pin consumer) are skipped here because
# they do not exercise the distribution's relative-path layout and are covered
# by the dedicated registry-pin handling in the static-validate job.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if ! command -v terraform >/dev/null 2>&1; then
  echo "terraform is required for smoke-customer-dist.sh" >&2
  exit 2
fi

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

TARBALL="${WORKDIR}/honua-terraform.tar.gz"
DIST="${WORKDIR}/dist"

echo "==> Building customer distribution tarball"
bash "${REPO_ROOT}/scripts/package-customer-dist.sh" "$TARBALL" >/dev/null

echo "==> Extracting tarball to a clean directory"
mkdir -p "$DIST"
tar -xzf "$TARBALL" -C "$DIST"

if [ ! -d "${DIST}/examples" ]; then
  echo "Packaged tarball has no examples/ directory" >&2
  exit 1
fi

initialized=0
skipped=0
failures=0

for example in "${DIST}"/examples/*/; do
  [ -d "$example" ] || continue
  name="$(basename "$example")"

  # Only examples that consume a local (relative) module source exercise the
  # distribution's flat layout. Skip pure remote/git-source consumers.
  if ! grep -Rqs 'source[[:space:]]*=[[:space:]]*"\.\.' "$example"; then
    echo "-- skip ${name} (no relative module source)"
    skipped=$((skipped + 1))
    continue
  fi

  echo "::group::terraform init (tarball example: ${name})"
  if terraform -chdir="$example" init -backend=false -input=false -no-color; then
    echo "OK: ${name}"
    initialized=$((initialized + 1))
  else
    echo "FAILED: terraform init on packaged example ${name}" >&2
    failures=$((failures + 1))
  fi
  echo "::endgroup::"
done

echo "==> Packaged examples: ${initialized} init OK, ${skipped} skipped, ${failures} failed"

if [ "$failures" -ne 0 ]; then
  echo "Customer-distribution smoke test FAILED: ${failures} packaged example(s) could not terraform init from the published tarball." >&2
  exit 1
fi

if [ "$initialized" -eq 0 ]; then
  echo "Customer-distribution smoke test FAILED: no packaged example was initialized (expected at least one)." >&2
  exit 1
fi

echo "Customer-distribution smoke test passed: all packaged examples terraform init cleanly."

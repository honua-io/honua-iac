#!/usr/bin/env bash
# Build a clean customer distribution tarball from the Terraform modules.
#
# Usage:
#   ./scripts/package-customer-dist.sh [--output dist/honua-terraform.tar.gz]
#
# The resulting archive contains only what operators need:
#   modules/          Reusable Terraform modules
#   examples/         Deployable example stacks
#   bootstrap/        Least-privilege identity provisioning
#   README.md         Operator documentation
#
# Internal CI/CD artifacts (validation/, .github/, scripts/) are excluded.
# Module source paths in examples are rewritten from "../../modules/X" to
# "../modules/X" to match the flat distribution layout.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TF_ROOT="${REPO_ROOT}/infrastructure/terraform"
OUTPUT="${1:-dist/honua-terraform.tar.gz}"

# Resolve output path relative to repo root.
case "$OUTPUT" in
  /*) ;; # absolute — leave as-is
  *)  OUTPUT="${REPO_ROOT}/${OUTPUT}" ;;
esac

STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT

echo "Staging customer distribution..."

# Copy operator-facing directories.
cp -a "${TF_ROOT}/modules"   "${STAGING}/modules"
cp -a "${TF_ROOT}/examples"  "${STAGING}/examples"
cp -a "${TF_ROOT}/bootstrap" "${STAGING}/bootstrap"
cp    "${TF_ROOT}/README.md" "${STAGING}/README.md"

# Strip internal-only files from the staging area.
find "${STAGING}" -name '*.tftest.hcl' -delete
find "${STAGING}" -name '.terraform' -type d -exec rm -rf {} + 2>/dev/null || true
find "${STAGING}" -name '.terraform.lock.hcl' -delete 2>/dev/null || true

# Rewrite module source paths.
# In the repo, examples reference "../../modules/X". In the flat distribution
# layout (modules/ and examples/ are siblings), the correct path is "../modules/X".
find "${STAGING}/examples" -name '*.tf' -print0 | \
  xargs -0 sed -i 's|source *= *"../../modules/|source = "../modules/|g'

# Create output directory and archive.
mkdir -p "$(dirname "$OUTPUT")"
tar -czf "$OUTPUT" -C "$STAGING" .

echo "Customer distribution: ${OUTPUT}"
echo "Contents:"
tar -tzf "$OUTPUT" | head -30
echo "..."

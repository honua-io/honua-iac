#!/usr/bin/env bash
# Build a clean customer distribution tarball from the Terraform modules.
#
# Usage:
#   ./scripts/package-customer-dist.sh [--output dist/honua-terraform.tar.gz]
#
# The resulting archive contains the marketplace/operator install bundle:
#   modules/          Reusable Terraform modules
#   examples/         Deployable example stacks
#   bootstrap/        Least-privilege identity provisioning
#   marketplace/      Versioned bundle manifests and schema contracts
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

sync_tree() {
  local source_dir="$1"
  local dest_dir="$2"

  rsync -a \
    --exclude='.terraform/' \
    --exclude='.terraform.lock.hcl' \
    --exclude='*.tftest.hcl' \
    "$source_dir"/ "$dest_dir"/
}

# Copy operator-facing directories without initialized working directories or test fixtures.
mkdir -p "${STAGING}/modules" "${STAGING}/examples" "${STAGING}/bootstrap" "${STAGING}/marketplace"
sync_tree "${TF_ROOT}/modules" "${STAGING}/modules"
sync_tree "${TF_ROOT}/examples" "${STAGING}/examples"
sync_tree "${TF_ROOT}/bootstrap" "${STAGING}/bootstrap"
sync_tree "${TF_ROOT}/marketplace" "${STAGING}/marketplace"
cp "${TF_ROOT}/README.md" "${STAGING}/README.md"

if ! find "${STAGING}/marketplace/bundles" -maxdepth 1 -type f -name '*.json' | grep -q .; then
  echo "Expected marketplace bundle manifests under marketplace/bundles" >&2
  exit 1
fi

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
tar -tzf "$OUTPUT" | sed -n '1,30p'
echo "..."

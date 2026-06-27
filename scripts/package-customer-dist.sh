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
# The examples/<stack>/ nesting is preserved in the distribution, so the existing
# "../../modules/X" relative module sources already resolve correctly
# (examples/<stack>/../../modules == modules); no path rewrite is performed. A
# guard below fails the build if any example module source fails to resolve.

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
    --exclude='.terraform.tfstate.lock.info' \
    --exclude='terraform.tfstate' \
    --exclude='terraform.tfstate.*' \
    --exclude='*.tfplan' \
    --exclude='crash.log' \
    --exclude='terraform.tfvars' \
    --exclude='*.auto.tfvars' \
    --exclude='*.auto.tfvars.json' \
    --exclude='backend.tf' \
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

# Drop Honua-owned, maintainer-only examples that are not part of the operator
# install surface and depend on infrastructure (components/) that the customer
# distribution intentionally does not ship. aws-cert is the real-AWS
# certification stack (GitHub-OIDC federation, cost guardrails) — it references
# ../../components/aws-github-oidc and cannot init outside the Honua account.
rm -rf "${STAGING}/examples/aws-cert"

if ! find "${STAGING}/marketplace/bundles" -maxdepth 1 -type f -name '*.json' | grep -q .; then
  echo "Expected marketplace bundle manifests under marketplace/bundles" >&2
  exit 1
fi

# Fail the build if any marketplace manifest references a path (sampleTfvars,
# schema, example/module root, bundle manifest) that does not exist in the repo.
"${REPO_ROOT}/scripts/check-marketplace-paths.sh"

# Smoke guard: verify every relative example module source resolves to a real
# directory inside the staged tree. Each example lives in examples/<stack>/, so
# "../../modules/X" already points at the staged modules/X; the source paths are
# intentionally NOT rewritten. This fails the build if a relative module source
# ever dangles (e.g. a reintroduced path rewrite), instead of shipping a tarball
# that cannot `terraform init`.
unresolved=0
while IFS= read -r -d '' tf; do
  tf_dir=$(dirname "$tf")
  while IFS= read -r src; do
    if ! (cd "$tf_dir" && cd "$src") >/dev/null 2>&1; then
      echo "Unresolved module source in ${tf#"${STAGING}"/}: $src" >&2
      unresolved=1
    fi
  done < <(grep -hoE 'source[[:space:]]*=[[:space:]]*"\.\.[^"]*"' "$tf" \
    | sed -E 's/.*"(\.\.[^"]*)".*/\1/')
done < <(find "${STAGING}/examples" -name '*.tf' -print0)

if [ "$unresolved" -ne 0 ]; then
  echo "Packaging aborted: one or more example module sources do not resolve in the distribution." >&2
  exit 1
fi

# Create output directory and archive.
mkdir -p "$(dirname "$OUTPUT")"
tar -czf "$OUTPUT" -C "$STAGING" .

echo "Customer distribution: ${OUTPUT}"
echo "Contents:"
tar -tzf "$OUTPUT" | sed -n '1,30p'
echo "..."

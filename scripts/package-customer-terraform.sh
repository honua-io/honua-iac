#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_DIR="${1:-$REPO_ROOT/dist/customer-terraform}"

copy_path() {
  local relative_path="$1"
  local source_path="$REPO_ROOT/$relative_path"
  local target_path="$OUTPUT_DIR/$relative_path"

  mkdir -p "$(dirname "$target_path")"
  cp -R "$source_path" "$target_path"
}

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

paths=(
  "README.md"
  "docs/operator-deployment.md"
  "docs/operator-state.md"
  "infrastructure/terraform/README.md"
  "infrastructure/terraform/bootstrap"
  "infrastructure/terraform/platforms"
  "infrastructure/terraform/components"
  "infrastructure/terraform/stacks/customer"
  "infrastructure/terraform/examples"
  "infrastructure/terraform/modules"
)

for path in "${paths[@]}"; do
  copy_path "$path"
done

cat > "$OUTPUT_DIR/PACKAGE_CONTENTS.txt" <<EOF
Customer Terraform bundle generated from:
$REPO_ROOT

Included:
- root operator README
- operator deployment/state guides
- bootstrap identities
- canonical platforms/components/customer stacks
- examples and modules compatibility wrappers

Excluded:
- .github workflows
- infrastructure/terraform/stacks/test
- infrastructure/terraform/validation
- docs/devops
- docs/adr
EOF

printf 'Wrote customer bundle to %s\n' "$OUTPUT_DIR"

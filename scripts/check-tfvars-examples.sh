#!/usr/bin/env bash
# Verify the operator tfvars contract for the four primary deployable roots.
#
# The documented operator path is:
#
#   cp terraform.tfvars.example terraform.tfvars   # fill in image + secrets
#   terraform plan [-var-file=presets/small.tfvars.example]
#
# `terraform validate` never reads a tfvars file, so CI can validate every root
# and still ship an example that is missing a required variable — the operator
# only finds out at plan time. This script closes that gap without needing
# cloud credentials:
#
#   1. every root variable without a default is assigned by the root
#      terraform.tfvars.example (otherwise `terraform plan` prompts or fails);
#   2. every key in terraform.tfvars.example and presets/small.tfvars.example
#      is a variable the root actually declares (catches drift after a root or
#      module change — Terraform rejects undeclared variables in a var file);
#   3. keys that both files set are reported, because a preset supplied with
#      -var-file wins outright for those variables and does not deep-merge.
#
# Usage: ./scripts/check-tfvars-examples.sh
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
examples_dir="$repo_root/infrastructure/terraform/examples"

roots=(
  aws
  azure
  aws-serverless
  azure-functions
)

failures=0

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

# Top-level variable names declared by a Terraform root, one per line.
# With --required-only, emit only the variables that have no default and so
# must be supplied by the operator.
declared_variables() {
  local root_dir="$1" required_only="${2:-}"
  awk -v required_only="$required_only" '
    { line = $0; sub(/#.*/, "", line); sub(/\/\/.*/, "", line) }

    depth == 0 && line ~ /^variable[[:space:]]+"[^"]+"[[:space:]]*\{/ {
      name = line
      sub(/^variable[[:space:]]+"/, "", name)
      sub(/".*/, "", name)
      in_variable = 1
      has_default = 0
    }

    in_variable && depth == 1 && line ~ /^[[:space:]]*default[[:space:]]*=/ { has_default = 1 }

    {
      n = gsub(/\{/, "{", line)
      m = gsub(/\}/, "}", line)
      depth += n - m
    }

    in_variable && depth == 0 {
      if (required_only == "" || !has_default) print name
      in_variable = 0
    }
  ' "$root_dir"/*.tf | sort -u
}

# Top-level keys assigned by a tfvars file, one per line. Nested keys (for
# example inside a `tags = { ... }` block) are deliberately ignored.
assigned_keys() {
  local tfvars_file="$1"
  awk '
    { line = $0; sub(/#.*/, "", line); sub(/\/\/.*/, "", line) }

    depth == 0 && line ~ /^[a-zA-Z_][a-zA-Z0-9_-]*[[:space:]]*=/ {
      key = line
      sub(/[[:space:]]*=.*/, "", key)
      print key
    }

    {
      n = gsub(/\{/, "{", line)
      m = gsub(/\}/, "}", line)
      depth += n - m
    }
  ' "$tfvars_file" | sort -u
}

check_declared() {
  local label="$1" tfvars_file="$2" declared="$3"
  local unknown
  unknown="$(comm -23 <(assigned_keys "$tfvars_file") <(printf '%s\n' "$declared"))"
  if [[ -n "$unknown" ]]; then
    fail "$label sets variables the root does not declare: $(tr '\n' ' ' <<<"$unknown")"
  fi
}

for root in "${roots[@]}"; do
  root_dir="$examples_dir/$root"
  example="$root_dir/terraform.tfvars.example"
  preset="$root_dir/presets/small.tfvars.example"

  printf '==> %s\n' "infrastructure/terraform/examples/$root"

  for required_file in "$example" "$preset"; do
    if [[ ! -f "$required_file" ]]; then
      fail "missing ${required_file#"$repo_root"/}"
      continue 2
    fi
  done

  declared="$(declared_variables "$root_dir")"
  required="$(declared_variables "$root_dir" --required-only)"

  missing="$(comm -23 <(printf '%s\n' "$required") <(assigned_keys "$example"))"
  if [[ -n "$missing" ]]; then
    fail "$root/terraform.tfvars.example does not assign required variables: $(tr '\n' ' ' <<<"$missing")"
  else
    printf '    required variables assigned: %s\n' "$(tr '\n' ' ' <<<"$required")"
  fi

  check_declared "$root/terraform.tfvars.example" "$example" "$declared"
  check_declared "$root/presets/small.tfvars.example" "$preset" "$declared"

  overlap="$(comm -12 <(assigned_keys "$example") <(assigned_keys "$preset"))"
  if [[ -n "$overlap" ]]; then
    printf '    preset overrides (last -var-file wins, no deep merge): %s\n' "$(tr '\n' ' ' <<<"$overlap")"
  fi
done

if ((failures > 0)); then
  printf '\n%d tfvars example check(s) failed.\n' "$failures" >&2
  exit 1
fi

printf '\nAll tfvars example checks passed.\n'

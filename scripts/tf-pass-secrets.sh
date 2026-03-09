#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/tf-secret-catalog.sh
source "$SCRIPT_DIR/lib/tf-secret-catalog.sh"

DEFAULT_REPO="honua-io/honua-terraform"

usage() {
  cat <<'EOF'
Usage:
  scripts/tf-pass-secrets.sh <command> [options]

Commands:
  import       Import env vars into pass entries
  export       Emit shell exports from pass for local runs
  sync-gh      Push pass entries to GitHub Actions secrets
  paths        Print the pass path for each managed secret
  help         Show this help

Common options:
  --scope <terraform|publish|all>  Secret scope (default: terraform)
  --prefix <pass-prefix>           pass prefix (default: honua/terraform)

Import options:
  --env-file <path>                Source a shell env file before importing
  --force                          Overwrite existing pass entries

Export options:
  --no-export-prefix               Emit KEY=... instead of export KEY=...

sync-gh options:
  --repo <owner/repo>              Target repository (repeatable; default: honua-io/honua-terraform)
  --dry-run                        Print what would be updated without writing secrets

Examples:
  source <(scripts/tf-pass-secrets.sh export)
  scripts/tf-pass-secrets.sh import --env-file scripts/tf-secrets.local.sh --force
  scripts/tf-pass-secrets.sh sync-gh --repo honua-io/honua-terraform
  scripts/tf-pass-secrets.sh sync-gh --scope publish --repo honua-io/honua-server
EOF
}

assert_pass_ready() {
  if ! command -v pass >/dev/null 2>&1; then
    echo "error: pass not found" >&2
    exit 1
  fi
}

assert_gh_ready() {
  if ! command -v gh >/dev/null 2>&1; then
    echo "error: gh CLI not found" >&2
    exit 1
  fi
  if ! gh auth status >/dev/null 2>&1; then
    echo "error: gh CLI not authenticated; run 'gh auth login'" >&2
    exit 1
  fi
}

pass_path_for_key() {
  local prefix="$1"
  local key="$2"

  printf '%s/%s\n' "$prefix" "$key"
}

load_scope_keys() {
  local scope="$1"
  mapfile -t SCOPE_KEYS < <(tf_secret_scope_keys "$scope")
  mapfile -t REQUIRED_KEYS < <(tf_secret_scope_required_keys "$scope")
}

report_missing_keys() {
  local -n required_ref="$1"
  local -n optional_ref="$2"

  if [[ ${#required_ref[@]} -gt 0 ]]; then
    printf 'Missing required: %s\n' "${required_ref[@]}" >&2
  fi

  if [[ ${#optional_ref[@]} -gt 0 ]]; then
    printf 'Missing optional: %s\n' "${optional_ref[@]}" >&2
  fi
}

import_command() {
  local scope="terraform"
  local prefix="$TF_PASS_DEFAULT_PREFIX"
  local env_file=""
  local force=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --scope)
        scope="${2:-}"
        shift 2
        ;;
      --prefix)
        prefix="${2:-}"
        shift 2
        ;;
      --env-file)
        env_file="${2:-}"
        shift 2
        ;;
      --force)
        force=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "error: unknown option '$1'" >&2
        usage
        exit 1
        ;;
    esac
  done

  assert_pass_ready
  load_scope_keys "$scope"

  if [[ -n "$env_file" ]]; then
    if [[ ! -f "$env_file" ]]; then
      echo "error: env file not found: $env_file" >&2
      exit 1
    fi
    set -a
    # shellcheck source=/dev/null
    source "$env_file"
    set +a
  fi

  local -a imported=()
  local -a missing_required=()
  local -a missing_optional=()
  local key=""
  local value=""
  local path=""
  local insert_args=(-m)

  if [[ "$force" -eq 1 ]]; then
    insert_args+=(-f)
  fi

  for key in "${SCOPE_KEYS[@]}"; do
    value="${!key:-}"
    if ! tf_secret_value_is_present "$value"; then
      if tf_secret_contains "$key" "${REQUIRED_KEYS[@]}"; then
        missing_required+=("$key")
      else
        missing_optional+=("$key")
      fi
      continue
    fi

    path="$(pass_path_for_key "$prefix" "$key")"
    printf '%s\n' "$value" | pass insert "${insert_args[@]}" "$path" >/dev/null
    imported+=("$key")
  done

  echo "Imported ${#imported[@]} secrets into pass prefix '$prefix'"
  if [[ ${#imported[@]} -gt 0 ]]; then
    printf 'Imported: %s\n' "${imported[@]}"
  fi

  report_missing_keys missing_required missing_optional

  if [[ ${#missing_required[@]} -gt 0 ]]; then
    exit 2
  fi
}

export_command() {
  local scope="terraform"
  local prefix="$TF_PASS_DEFAULT_PREFIX"
  local include_export_prefix=1

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --scope)
        scope="${2:-}"
        shift 2
        ;;
      --prefix)
        prefix="${2:-}"
        shift 2
        ;;
      --no-export-prefix)
        include_export_prefix=0
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "error: unknown option '$1'" >&2
        usage
        exit 1
        ;;
    esac
  done

  assert_pass_ready
  load_scope_keys "$scope"

  local -a missing_required=()
  local -a missing_optional=()
  local key=""
  local value=""
  local path=""

  for key in "${SCOPE_KEYS[@]}"; do
    path="$(pass_path_for_key "$prefix" "$key")"
    if ! value="$(pass show "$path" 2>/dev/null)"; then
      if tf_secret_contains "$key" "${REQUIRED_KEYS[@]}"; then
        missing_required+=("$key")
      else
        missing_optional+=("$key")
      fi
      continue
    fi

    if [[ "$include_export_prefix" -eq 1 ]]; then
      printf 'export %s=%q\n' "$key" "$value"
    else
      printf '%s=%q\n' "$key" "$value"
    fi
  done

  report_missing_keys missing_required missing_optional

  if [[ ${#missing_required[@]} -gt 0 ]]; then
    exit 2
  fi
}

sync_gh_command() {
  local scope="terraform"
  local prefix="$TF_PASS_DEFAULT_PREFIX"
  local dry_run=0
  local -a repos=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --scope)
        scope="${2:-}"
        shift 2
        ;;
      --prefix)
        prefix="${2:-}"
        shift 2
        ;;
      --repo)
        repos+=("${2:-}")
        shift 2
        ;;
      --dry-run)
        dry_run=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "error: unknown option '$1'" >&2
        usage
        exit 1
        ;;
    esac
  done

  assert_pass_ready
  assert_gh_ready
  load_scope_keys "$scope"

  if [[ ${#repos[@]} -eq 0 ]]; then
    repos=("$DEFAULT_REPO")
  fi

  local -a missing_required=()
  local -a missing_optional=()
  local -a updated=()
  local repo=""
  local key=""
  local value=""
  local path=""

  for key in "${SCOPE_KEYS[@]}"; do
    path="$(pass_path_for_key "$prefix" "$key")"
    if ! value="$(pass show "$path" 2>/dev/null)"; then
      if tf_secret_contains "$key" "${REQUIRED_KEYS[@]}"; then
        missing_required+=("$key")
      else
        missing_optional+=("$key")
      fi
      continue
    fi

    for repo in "${repos[@]}"; do
      if [[ "$dry_run" -eq 1 ]]; then
        updated+=("${repo}:${key}")
        continue
      fi

      gh secret set "$key" --repo "$repo" --body "$value" >/dev/null
      updated+=("${repo}:${key}")
    done
  done

  if [[ "$dry_run" -eq 1 ]]; then
    echo "Dry run: would set ${#updated[@]} secrets"
  else
    echo "Set ${#updated[@]} secrets"
  fi

  if [[ ${#updated[@]} -gt 0 ]]; then
    printf 'Updated: %s\n' "${updated[@]}"
  fi

  report_missing_keys missing_required missing_optional

  if [[ ${#missing_required[@]} -gt 0 ]]; then
    exit 2
  fi
}

paths_command() {
  local scope="terraform"
  local prefix="$TF_PASS_DEFAULT_PREFIX"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --scope)
        scope="${2:-}"
        shift 2
        ;;
      --prefix)
        prefix="${2:-}"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "error: unknown option '$1'" >&2
        usage
        exit 1
        ;;
    esac
  done

  load_scope_keys "$scope"

  local key=""
  for key in "${SCOPE_KEYS[@]}"; do
    printf '%s -> %s\n' "$key" "$(pass_path_for_key "$prefix" "$key")"
  done
}

main() {
  local command="${1:-help}"
  if [[ $# -gt 0 ]]; then
    shift
  fi

  case "$command" in
    import)
      import_command "$@"
      ;;
    export)
      export_command "$@"
      ;;
    sync-gh)
      sync_gh_command "$@"
      ;;
    paths)
      paths_command "$@"
      ;;
    help|-h|--help)
      usage
      ;;
    *)
      echo "error: unknown command '$command'" >&2
      usage
      exit 1
      ;;
  esac
}

main "$@"

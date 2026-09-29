#!/usr/bin/env bash

# Sweep orphaned per-run validation IAM principals and validation log groups.
#
# terraform-manual-validation mints per-run IAM users (honua-tf-{ecs,sls,eks}-
# <run-id>-<attempt>) with active access keys, and the validation stacks create
# IAM roles/policies tagged Owner=terraform-validation. When a run is
# cancelled, times out, or the runner is lost, the in-step EXIT traps never
# finish and those credentials-bearing principals leak. The existing in-run
# leak janitor cannot see them because the Resource Groups Tagging API does not
# index IAM resources.
#
# This sweeper closes that gap. It is safe to run repeatedly (idempotent) and
# always enumerates read-only first, prints the deletion plan, and only then
# deletes (skipped entirely with --dry-run).
#
# Deletion criteria:
#   - IAM users named honua-tf-*: deleted when their ExpiresAtUTC tag is in the
#     past, or (for untagged historical users) when older than --max-age-hours.
#     Access keys are deactivated and deleted before the user is removed.
#   - IAM users passed via --user: deleted unconditionally (used by the
#     workflow post-run cleanup for the current run's principals, covering the
#     case where terraform crashed before writing state).
#   - IAM roles/customer-managed policies tagged Owner=terraform-validation:
#     deleted when their ExpiresAtUTC tag is in the past. Untagged or
#     unexpired resources are left alone.
#   - CloudWatch log groups /aws/ecs/containerinsights/*-it-*: deleted when
#     older than --max-age-hours (auto-created by Container Insights for
#     validation clusters; terraform destroy never removes them).
#     /aws/batch/job gets a 1-day retention policy instead of deletion.
#
# Resources tagged with a ValidationRunId passed via --protect-run-id are
# never touched regardless of expiry.

set -euo pipefail

log_info() { echo "[INFO] $*"; }
log_warn() { echo "[WARN] $*" >&2; }
log_error() { echo "[ERROR] $*" >&2; }

usage() {
  cat <<'USAGE'
Usage: sweep-orphaned-validation-iam.sh [options]

Options:
  --max-age-hours <n>     Age threshold for resources without an ExpiresAtUTC
                          tag (default: 24)
  --dry-run               Enumerate and print the deletion plan only
  --user <name>           Purge this exact IAM user (and its <name>-policy)
                          unconditionally; repeatable
  --protect-run-id <id>   Never touch resources tagged ValidationRunId=<id>;
                          repeatable
  --region <region>       Region to sweep log groups in; repeatable
                          (default: $AWS_REGION/$AWS_DEFAULT_REGION if set)
  --skip-log-groups       Skip the CloudWatch log group sweep
  -h, --help              Show this help
USAGE
}

MAX_AGE_HOURS=24
DRY_RUN=false
SKIP_LOG_GROUPS=false
TARGET_USERS=()
PROTECT_RUN_IDS=()
REGIONS=()
FAILURES=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --max-age-hours)
      MAX_AGE_HOURS="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --user)
      TARGET_USERS+=("$2")
      shift 2
      ;;
    --protect-run-id)
      PROTECT_RUN_IDS+=("$2")
      shift 2
      ;;
    --region)
      REGIONS+=("$2")
      shift 2
      ;;
    --skip-log-groups)
      SKIP_LOG_GROUPS=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      log_error "Unknown argument: $1"
      usage
      exit 1
      ;;
  esac
done

if ! [[ "$MAX_AGE_HOURS" =~ ^[0-9]+$ ]] || (( MAX_AGE_HOURS < 1 )); then
  log_error "--max-age-hours must be a positive integer (got '$MAX_AGE_HOURS')"
  exit 1
fi

for cmd in aws jq; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    log_error "Required command not found: $cmd"
    exit 1
  fi
done

if [[ ${#REGIONS[@]} -eq 0 ]]; then
  default_region="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
  if [[ -n "$default_region" ]]; then
    REGIONS+=("$default_region")
  fi
fi

NOW_EPOCH="$(date -u +%s)"
CUTOFF_EPOCH=$(( NOW_EPOCH - MAX_AGE_HOURS * 3600 ))

epoch_of() {
  date -u -d "$1" +%s 2>/dev/null || echo ""
}

is_protected_run_id() {
  local run_id="$1"
  local protected
  [[ -z "$run_id" ]] && return 1
  for protected in ${PROTECT_RUN_IDS[@]+"${PROTECT_RUN_IDS[@]}"}; do
    if [[ "$run_id" == "$protected" ]]; then
      return 0
    fi
  done
  return 1
}

is_target_user() {
  local user="$1"
  local target
  for target in ${TARGET_USERS[@]+"${TARGET_USERS[@]}"}; do
    if [[ "$user" == "$target" ]]; then
      return 0
    fi
  done
  return 1
}

# Extract a tag value from a JSON tag list ({"Tags":[{"Key":..,"Value":..}]}).
tag_value() {
  local tags_json="$1"
  local key="$2"
  jq -r --arg k "$key" '.Tags[]? | select(.Key == $k) | .Value' <<<"$tags_json" | head -n1
}

# Decide whether a resource is an expired orphan.
#   $1 = tags JSON, $2 = CreateDate (ISO), $3 = allow age fallback (true/false)
# Prints the reason on stdout and returns 0 when the resource should go.
orphan_reason() {
  local tags_json="$1"
  local create_date="$2"
  local allow_age_fallback="$3"
  local run_id expires_at expires_epoch create_epoch

  run_id="$(tag_value "$tags_json" ValidationRunId)"
  if is_protected_run_id "$run_id"; then
    return 1
  fi

  expires_at="$(tag_value "$tags_json" ExpiresAtUTC)"
  if [[ -n "$expires_at" ]]; then
    expires_epoch="$(epoch_of "$expires_at")"
    if [[ -z "$expires_epoch" ]]; then
      return 1
    fi
    if (( expires_epoch <= NOW_EPOCH )); then
      echo "ExpiresAtUTC=$expires_at elapsed (run=${run_id:-unknown})"
      return 0
    fi
    return 1
  fi

  if [[ "$allow_age_fallback" == "true" && -n "$create_date" ]]; then
    create_epoch="$(epoch_of "$create_date")"
    if [[ -n "$create_epoch" ]] && (( create_epoch <= CUTOFF_EPOCH )); then
      echo "no ExpiresAtUTC tag and older than ${MAX_AGE_HOURS}h (created $create_date)"
      return 0
    fi
  fi

  return 1
}

run_delete() {
  local output
  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[dry-run] would run: $*"
    return 0
  fi
  if output="$("$@" 2>&1)"; then
    return 0
  fi
  # Another sweep (or the in-run trap) already removed it: that is success.
  if grep -q 'NoSuchEntity' <<<"$output"; then
    return 0
  fi
  log_warn "Command failed: $* :: $output"
  FAILURES=$(( FAILURES + 1 ))
  return 1
}

# ---------------------------------------------------------------------------
# IAM users (honua-tf-* bootstrap users with access keys)
# ---------------------------------------------------------------------------

purge_user() {
  local user="$1"
  local reason="$2"
  local key arn policy_name group

  if ! aws iam get-user --user-name "$user" >/dev/null 2>&1; then
    log_info "IAM user $user does not exist; nothing to purge"
    return 0
  fi

  log_warn "Purging IAM user $user ($reason)"

  while IFS= read -r key; do
    [[ -z "$key" || "$key" == "None" ]] && continue
    run_delete aws iam update-access-key --user-name "$user" --access-key-id "$key" --status Inactive || true
    run_delete aws iam delete-access-key --user-name "$user" --access-key-id "$key" || true
  done < <(aws iam list-access-keys --user-name "$user" \
    --query 'AccessKeyMetadata[].AccessKeyId' --output text 2>/dev/null | tr '\t' '\n')

  while IFS= read -r arn; do
    [[ -z "$arn" || "$arn" == "None" ]] && continue
    run_delete aws iam detach-user-policy --user-name "$user" --policy-arn "$arn" || true
  done < <(aws iam list-attached-user-policies --user-name "$user" \
    --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null | tr '\t' '\n')

  while IFS= read -r policy_name; do
    [[ -z "$policy_name" || "$policy_name" == "None" ]] && continue
    run_delete aws iam delete-user-policy --user-name "$user" --policy-name "$policy_name" || true
  done < <(aws iam list-user-policies --user-name "$user" \
    --query 'PolicyNames[]' --output text 2>/dev/null | tr '\t' '\n')

  while IFS= read -r group; do
    [[ -z "$group" || "$group" == "None" ]] && continue
    run_delete aws iam remove-user-from-group --user-name "$user" --group-name "$group" || true
  done < <(aws iam list-groups-for-user --user-name "$user" \
    --query 'Groups[].GroupName' --output text 2>/dev/null | tr '\t' '\n')

  if [[ "$DRY_RUN" != "true" ]]; then
    aws iam delete-login-profile --user-name "$user" >/dev/null 2>&1 || true
  fi

  run_delete aws iam delete-user --user-name "$user" || true
}

delete_policy_by_arn() {
  local arn="$1"
  local version

  # shellcheck disable=SC2016  # JMESPath backticks, not shell expansion
  while IFS= read -r version; do
    [[ -z "$version" || "$version" == "None" ]] && continue
    run_delete aws iam delete-policy-version --policy-arn "$arn" --version-id "$version" || true
  done < <(aws iam list-policy-versions --policy-arn "$arn" \
    --query 'Versions[?IsDefaultVersion==`false`].VersionId' --output text 2>/dev/null | tr '\t' '\n')

  run_delete aws iam delete-policy --policy-arn "$arn" || true
}

sweep_users() {
  local users_json user create_date tags_json reason
  local -a orphan_users=()
  local -a orphan_reasons=()

  log_info "Enumerating IAM users with prefix honua-tf-"
  # shellcheck disable=SC2016  # JMESPath backticks, not shell expansion
  users_json="$(aws iam list-users \
    --query 'Users[?starts_with(UserName, `honua-tf-`)].{Name:UserName,Created:CreateDate}' \
    --output json)"

  while IFS=$'\t' read -r user create_date; do
    [[ -z "$user" ]] && continue

    if is_target_user "$user"; then
      orphan_users+=("$user")
      orphan_reasons+=("targeted by --user")
      continue
    fi

    tags_json="$(aws iam list-user-tags --user-name "$user" --output json 2>/dev/null || echo '{"Tags":[]}')"
    if reason="$(orphan_reason "$tags_json" "$create_date" true)"; then
      orphan_users+=("$user")
      orphan_reasons+=("$reason")
    fi
  done < <(jq -r '.[] | [.Name, .Created] | @tsv' <<<"$users_json")

  # Targeted users may not have shown up in the listing (already deleted, or
  # created moments ago under eventual consistency); purge_user handles
  # missing users gracefully, so include any that were not matched above.
  local target found
  for target in ${TARGET_USERS[@]+"${TARGET_USERS[@]}"}; do
    found=false
    for user in ${orphan_users[@]+"${orphan_users[@]}"}; do
      [[ "$user" == "$target" ]] && found=true && break
    done
    if [[ "$found" == "false" ]]; then
      orphan_users+=("$target")
      orphan_reasons+=("targeted by --user")
    fi
  done

  if [[ ${#orphan_users[@]} -eq 0 ]]; then
    log_info "No orphaned validation IAM users found"
    return 0
  fi

  local i
  log_info "Plan: ${#orphan_users[@]} IAM user(s) to purge:"
  for i in "${!orphan_users[@]}"; do
    log_info "  - ${orphan_users[$i]} (${orphan_reasons[$i]})"
  done

  for i in "${!orphan_users[@]}"; do
    purge_user "${orphan_users[$i]}" "${orphan_reasons[$i]}"
  done
}

# ---------------------------------------------------------------------------
# IAM roles tagged Owner=terraform-validation
# ---------------------------------------------------------------------------

purge_role() {
  local role="$1"
  local reason="$2"
  local profile arn policy_name

  if ! aws iam get-role --role-name "$role" >/dev/null 2>&1; then
    log_info "IAM role $role does not exist; nothing to purge"
    return 0
  fi

  log_warn "Purging IAM role $role ($reason)"

  while IFS= read -r profile; do
    [[ -z "$profile" || "$profile" == "None" ]] && continue
    run_delete aws iam remove-role-from-instance-profile --instance-profile-name "$profile" --role-name "$role" || true
    if [[ "$DRY_RUN" != "true" ]]; then
      aws iam delete-instance-profile --instance-profile-name "$profile" >/dev/null 2>&1 || true
    fi
  done < <(aws iam list-instance-profiles-for-role --role-name "$role" \
    --query 'InstanceProfiles[].InstanceProfileName' --output text 2>/dev/null | tr '\t' '\n')

  while IFS= read -r arn; do
    [[ -z "$arn" || "$arn" == "None" ]] && continue
    run_delete aws iam detach-role-policy --role-name "$role" --policy-arn "$arn" || true
  done < <(aws iam list-attached-role-policies --role-name "$role" \
    --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null | tr '\t' '\n')

  while IFS= read -r policy_name; do
    [[ -z "$policy_name" || "$policy_name" == "None" ]] && continue
    run_delete aws iam delete-role-policy --role-name "$role" --policy-name "$policy_name" || true
  done < <(aws iam list-role-policies --role-name "$role" \
    --query 'PolicyNames[]' --output text 2>/dev/null | tr '\t' '\n')

  run_delete aws iam delete-role --role-name "$role" || true
}

sweep_roles() {
  local roles_json role path create_date tags_json owner reason
  local -a orphan_roles=()
  local -a orphan_role_reasons=()

  log_info "Enumerating IAM roles tagged Owner=terraform-validation"
  roles_json="$(aws iam list-roles \
    --query 'Roles[].{Name:RoleName,Path:Path,Created:CreateDate}' --output json)"

  while IFS=$'\t' read -r role path create_date; do
    [[ -z "$role" ]] && continue
    case "$path" in
      /aws-service-role/*) continue ;;
    esac

    tags_json="$(aws iam list-role-tags --role-name "$role" --output json 2>/dev/null || echo '{"Tags":[]}')"
    owner="$(tag_value "$tags_json" Owner)"
    if [[ "$owner" != "terraform-validation" ]]; then
      continue
    fi

    # Roles are only reaped on proven expiry; a validation-owned role without
    # a parseable ExpiresAtUTC cannot be proven orphaned, so it is left alone.
    if reason="$(orphan_reason "$tags_json" "$create_date" false)"; then
      orphan_roles+=("$role")
      orphan_role_reasons+=("$reason")
    fi
  done < <(jq -r '.[] | [.Name, .Path, .Created] | @tsv' <<<"$roles_json")

  if [[ ${#orphan_roles[@]} -eq 0 ]]; then
    log_info "No orphaned validation IAM roles found"
    return 0
  fi

  local i
  log_info "Plan: ${#orphan_roles[@]} IAM role(s) to purge:"
  for i in "${!orphan_roles[@]}"; do
    log_info "  - ${orphan_roles[$i]} (${orphan_role_reasons[$i]})"
  done

  for i in "${!orphan_roles[@]}"; do
    purge_role "${orphan_roles[$i]}" "${orphan_role_reasons[$i]}"
  done
}

# ---------------------------------------------------------------------------
# Customer-managed policies tagged Owner=terraform-validation, plus leftover
# honua-tf-*-policy bootstrap policies
# ---------------------------------------------------------------------------

sweep_policies() {
  local policies_json arn name create_date attachments tags_json owner reason allow_age
  local -a orphan_policy_arns=()
  local -a orphan_policy_labels=()

  log_info "Enumerating customer-managed IAM policies"
  policies_json="$(aws iam list-policies --scope Local \
    --query 'Policies[].{Arn:Arn,Name:PolicyName,Created:CreateDate,Attachments:AttachmentCount}' \
    --output json)"

  while IFS=$'\t' read -r arn name create_date attachments; do
    [[ -z "$arn" ]] && continue

    # Attached policies belong to principals handled by the user/role sweeps
    # in this same invocation; they will be picked up on the next run once
    # detached. Never force-detach here.
    if [[ "$attachments" != "0" ]]; then
      continue
    fi

    allow_age=false
    case "$name" in
      honua-tf-*) allow_age=true ;;
    esac

    tags_json="$(aws iam list-policy-tags --policy-arn "$arn" --output json 2>/dev/null || echo '{"Tags":[]}')"
    owner="$(tag_value "$tags_json" Owner)"
    if [[ "$owner" != "terraform-validation" && "$allow_age" != "true" ]]; then
      continue
    fi

    if reason="$(orphan_reason "$tags_json" "$create_date" "$allow_age")"; then
      orphan_policy_arns+=("$arn")
      orphan_policy_labels+=("$name ($reason)")
    fi
  done < <(jq -r '.[] | [.Arn, .Name, .Created, (.Attachments|tostring)] | @tsv' <<<"$policies_json")

  if [[ ${#orphan_policy_arns[@]} -eq 0 ]]; then
    log_info "No orphaned validation IAM policies found"
    return 0
  fi

  local i
  log_info "Plan: ${#orphan_policy_arns[@]} IAM policy(ies) to delete:"
  for i in "${!orphan_policy_labels[@]}"; do
    log_info "  - ${orphan_policy_labels[$i]}"
  done

  for i in "${!orphan_policy_arns[@]}"; do
    log_warn "Deleting IAM policy ${orphan_policy_labels[$i]}"
    delete_policy_by_arn "${orphan_policy_arns[$i]}"
  done
}

# ---------------------------------------------------------------------------
# Validation log groups (auto-created by Container Insights / Batch; never in
# terraform state, so terraform destroy leaves them behind)
# ---------------------------------------------------------------------------

sweep_log_groups_in_region() {
  local region="$1"
  local groups_json group_name created_ms created_epoch
  local -a orphan_groups=()

  log_info "Enumerating Container Insights log groups in $region"
  groups_json="$(aws logs describe-log-groups --region "$region" \
    --log-group-name-prefix '/aws/ecs/containerinsights/' \
    --query 'logGroups[].{Name:logGroupName,Created:creationTime}' --output json 2>/dev/null || echo '[]')"

  while IFS=$'\t' read -r group_name created_ms; do
    [[ -z "$group_name" ]] && continue
    # Only validation clusters: the integration environment is always "it",
    # producing cluster names like <prefix>-it-cluster.
    case "$group_name" in
      /aws/ecs/containerinsights/*-it-cluster/*) ;;
      /aws/ecs/containerinsights/*-it/*) ;;
      *) continue ;;
    esac

    created_epoch=$(( created_ms / 1000 ))
    if (( created_epoch <= CUTOFF_EPOCH )); then
      orphan_groups+=("$group_name")
    fi
  done < <(jq -r '.[] | [.Name, (.Created|tostring)] | @tsv' <<<"$groups_json")

  if [[ ${#orphan_groups[@]} -gt 0 ]]; then
    log_info "Plan: ${#orphan_groups[@]} log group(s) to delete in $region:"
    local group
    for group in "${orphan_groups[@]}"; do
      log_info "  - $group"
    done
    for group in "${orphan_groups[@]}"; do
      run_delete aws logs delete-log-group --region "$region" --log-group-name "$group" || true
    done
  else
    log_info "No orphaned validation log groups found in $region"
  fi

  # /aws/batch/job is a shared auto-created group; cap retention instead of
  # deleting so an in-flight run is never disrupted.
  # shellcheck disable=SC2016  # JMESPath backticks, not shell expansion
  if aws logs describe-log-groups --region "$region" \
    --log-group-name-prefix '/aws/batch/job' \
    --query 'logGroups[?logGroupName==`/aws/batch/job`] | [0].logGroupName' \
    --output text 2>/dev/null | grep -q '^/aws/batch/job$'; then
    run_delete aws logs put-retention-policy --region "$region" \
      --log-group-name '/aws/batch/job' --retention-in-days 1 || true
  fi
}

sweep_log_groups() {
  if [[ "$SKIP_LOG_GROUPS" == "true" ]]; then
    return 0
  fi
  if [[ ${#REGIONS[@]} -eq 0 ]]; then
    log_warn "No region configured (use --region or AWS_REGION); skipping log group sweep"
    return 0
  fi
  local region
  for region in "${REGIONS[@]}"; do
    sweep_log_groups_in_region "$region"
  done
}

main() {
  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "Running in dry-run mode: nothing will be deleted"
  fi
  log_info "Age threshold for untagged honua-tf-* resources: ${MAX_AGE_HOURS}h"

  sweep_users
  sweep_roles
  sweep_policies
  sweep_log_groups

  if (( FAILURES > 0 )); then
    log_error "Sweep finished with $FAILURES failed deletion command(s)"
    exit 1
  fi

  log_info "Sweep complete"
}

main

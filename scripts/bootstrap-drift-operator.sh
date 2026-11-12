#!/usr/bin/env bash
# Drift plan for the operator-applied bootstrap roots (drift-roots.json entries with "operator").
# Their inputs are SSM SecureStrings and their plans read EC2, CloudTrail, Config and SSM, which
# the nightly CI role cannot, so this runs with the operator's AWS credentials from a trunk checkout.
#
# Read-only: `terraform plan -lock=false`, a private TF_DATA_DIR, tfvars in a mode-700 temp dir.
# Opens, updates or closes the honua-iac issue "Terraform drift: operator-applied bootstrap
# roots do not match trunk". The issue lists addresses, actions and changed attribute names,
# never values: the inputs hold emails, CIDRs and keys.
#
# Usage: scripts/bootstrap-drift-operator.sh [root ...]    (default: every operator root)
# Exit: 0 clean, 2 drift, 1 a plan could not run.
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
terraform="${TERRAFORM:-terraform}"
manifest() { python3 "$repo/scripts/bootstrap-drift-roots.py" "$@"; }

git -C "$repo" fetch --quiet origin trunk
if [[ "$(git -C "$repo" rev-parse HEAD)" != "$(git -C "$repo" rev-parse origin/trunk)" ]] \
  || [[ -n "$(git -C "$repo" status --porcelain --untracked-files=no)" ]]; then
  echo "Run from a clean checkout of origin/trunk: drift is measured against trunk." >&2
  exit 1
fi

account="$(aws sts get-caller-identity --query Account --output text)"
state_bucket="${HONUA_TFSTATE_BUCKET:-honua-tfstate-$account}"
work="$(mktemp -d)"
chmod 700 "$work"
activated_backends=()
cleanup() {
  for backend in "${activated_backends[@]}"; do rm -f "$backend"; done
  rm -rf "$work"
}
trap cleanup EXIT

if [[ $# -gt 0 ]]; then roots=("$@"); else mapfile -t roots < <(manifest --operator-roots); fi

result=0
body="$work/body.md"
echo "Operator drift plan $(date -u +%Y-%m-%dT%H:%MZ), trunk \`$(git -C "$repo" rev-parse --short=12 HEAD)\`." > "$body"
for root in "${roots[@]}"; do
  dir="$repo/infrastructure/terraform/bootstrap/$root"
  operator="$(manifest --get "$root" operator)"
  parameter="$(jq -r .tfvars_parameter <<<"$operator")"
  region="$(jq -r .region <<<"$operator")"
  if [[ ! -f "$dir/backend.tf" ]]; then
    cp "$dir/backend.tf.example" "$dir/backend.tf"
    activated_backends+=("$dir/backend.tf")
  fi

  aws ssm get-parameter --region "$region" --name "$parameter" --with-decryption \
    --query Parameter.Value --output text > "$work/$root.tfvars"
  export TF_DATA_DIR="$work/$root.terraform"
  if ! "$terraform" -chdir="$dir" init -input=false -no-color -reconfigure \
      -backend-config="bucket=$state_bucket" \
      -backend-config="key=$(manifest --get "$root" state_key)" >"$work/$root.init" 2>&1; then
    echo "bootstrap/$root: init failed" >&2
    printf '\n### bootstrap/%s: init failed\n' "$root" >> "$body"
    result=1
    continue
  fi
  set +e
  "$terraform" -chdir="$dir" plan -input=false -no-color -lock=false -detailed-exitcode \
    -var-file="$work/$root.tfvars" -out="$work/$root.tfplan" >"$work/$root.plan" 2>&1
  code=$?
  set -e
  case "$code" in
    0) echo "bootstrap/$root: clean" ;;
    2)
      echo "bootstrap/$root: DRIFT"
      [[ "$result" == 1 ]] || result=2
      {
        printf '\n### bootstrap/%s: CHANGES\n\n' "$root"
        "$terraform" -chdir="$dir" show -json "$work/$root.tfplan" | jq -r '
          .resource_changes[]? | select(.change.actions != ["no-op"] and .change.actions != ["read"])
          | (.change.before // {}) as $b | (.change.after // {}) as $a
          | "- `\(.address)`: \(.change.actions | join(", "))"
            + (([$b, $a] | map(keys) | add | unique | map(select($b[.] != $a[.]))) as $k
               | if ($k | length) > 0 then " (" + ($k | join(", ")) + ")" else "" end)'
      } >> "$body"
      ;;
    *)
      echo "bootstrap/$root: plan failed" >&2
      grep -E '^(Error|│ Error)' "$work/$root.plan" | sed -E 's/[0-9]{12}/<account>/g' >&2 || true
      printf '\n### bootstrap/%s: plan failed\n' "$root" >> "$body"
      result=1
      ;;
  esac
done
unset TF_DATA_DIR

title="Terraform drift: operator-applied bootstrap roots do not match trunk"
existing="$(gh issue list -R honua-io/honua-iac --state open --search "\"$title\" in:title" --json number,title \
  --jq "map(select(.title == \"$title\")) | .[0].number // empty" </dev/null)"
if [[ "$result" == 0 ]]; then
  [[ -z "$existing" ]] || gh issue close "$existing" -R honua-io/honua-iac --reason completed \
    --comment "Every operator root plans clean at trunk $(git -C "$repo" rev-parse --short=12 HEAD)." </dev/null
  exit 0
fi
echo -e "\nFix drift by applying trunk from the root's README, or by a PR that makes trunk match. Never with the AWS CLI." >> "$body"
if [[ -n "$existing" ]]; then
  gh issue comment "$existing" -R honua-io/honua-iac --body-file "$body" </dev/null
else
  gh issue create -R honua-io/honua-iac --title "$title" --label drift --body-file "$body" </dev/null
fi
exit "$result"

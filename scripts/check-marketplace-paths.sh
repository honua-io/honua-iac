#!/usr/bin/env bash
# Verify every file path referenced by the marketplace manifests resolves to a
# real file in the repo, so the published install/deploy contract never points
# at artifacts that do not exist (sampleTfvars, schemas, example/module roots,
# bundle manifests). Exits non-zero if any referenced path is missing.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TF_ROOT="${REPO_ROOT}/infrastructure/terraform"
MARKET="${TF_ROOT}/marketplace"

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required for check-marketplace-paths.sh" >&2
  exit 2
fi

missing=0
check() {
  local label="$1" path="$2"
  if [ ! -e "$path" ]; then
    echo "MISSING (${label}): ${path#"${REPO_ROOT}"/}" >&2
    missing=1
  fi
}

# Bundles: installSurface.{schema,sampleTfvars} and deploySurface.schema are
# relative to each bundle file's own directory (marketplace/bundles/).
while IFS= read -r bundle; do
  bdir="$(dirname "$bundle")"
  while IFS= read -r rel; do
    [ -z "$rel" ] && continue
    check "$(basename "$bundle")" "${bdir}/${rel}"
  done < <(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
for section, key in (("installSurface", "schema"),
                     ("installSurface", "sampleTfvars"),
                     ("deploySurface", "schema")):
    v = d.get(section, {}).get(key)
    if v:
        print(v)
' "$bundle")
done < <(find "${MARKET}/bundles" -maxdepth 1 -type f -name '*.json' | sort)

# targets.json: exampleRoot/modulePath are relative to the Terraform root;
# bundleManifest is relative to the marketplace directory.
while IFS= read -r entry; do
  base="${entry%%|*}"
  rel="${entry#*|}"
  case "$base" in
    tf) check "targets.json" "${TF_ROOT}/${rel}" ;;
    mk) check "targets.json" "${MARKET}/${rel}" ;;
  esac
done < <(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
for t in d.get("targets", []):
    for k in ("exampleRoot", "modulePath"):
        if t.get(k):
            print("tf|" + t[k])
    if t.get("bundleManifest"):
        print("mk|" + t["bundleManifest"])
' "${MARKET}/targets.json")

if [ "$missing" -ne 0 ]; then
  echo "Marketplace manifest path check FAILED." >&2
  exit 1
fi

# Contract-conformance: every turnkey target with a bundle must actually declare
# the install input variable and the install_contract/deploy_contract outputs the
# manifests advertise, otherwise a consumer following the published contract gets
# nothing back. Assert their presence in the example root's Terraform.
nonconforming=0
assert_decl() {
  local kind="$1" name="$2" root="$3"
  if ! grep -Rqs "^[[:space:]]*${kind} \"${name}\"" "$root"; then
    echo "MISSING (${kind} \"${name}\"): not declared in ${root#"${REPO_ROOT}"/}" >&2
    nonconforming=1
  fi
}

assert_deploy_secret_ref() {
  local example_root="$1" key="$2" expected_value="$3"
  local file="${TF_ROOT}/${example_root}/marketplace.tf"
  local block

  block="$(awk '
    /^[[:space:]]*secret_refs[[:space:]]*=/ { capture = 1 }
    capture { print }
    capture && /^[[:space:]]*}[[:space:]]*:[[:space:]]*k[[:space:]]*=>[[:space:]]*v[[:space:]]*if[[:space:]]*v[[:space:]]*!=[[:space:]]*null[[:space:]]*}/ { exit }
  ' "$file")"

  if [ -z "$block" ] || ! printf '%s\n' "$block" | awk -v expected="${key} = ${expected_value}" '
    {
      line = $0
      sub(/#.*/, "", line)
      gsub(/[[:space:]]+/, " ", line)
      sub(/^ /, "", line)
      sub(/ $/, "", line)
      if (line == expected) found = 1
    }
    END { exit(found ? 0 : 1) }
  '; then
    echo "MISSING (deploy_contract.secret_refs.${key}): expected ${expected_value} in ${file#"${REPO_ROOT}"/}" >&2
    nonconforming=1
  fi
}
while IFS='|' read -r example_root input_var install_out deploy_out; do
  [ -z "$example_root" ] && continue
  root="${TF_ROOT}/${example_root}"
  [ -n "$input_var" ] && assert_decl "variable" "$input_var" "$root"
  [ -n "$install_out" ] && assert_decl "output" "$install_out" "$root"
  [ -n "$deploy_out" ] && assert_decl "output" "$deploy_out" "$root"
done < <(python3 -c '
import json, os, sys
mk = sys.argv[1]
d = json.load(open(os.path.join(mk, "targets.json")))
for t in d.get("targets", []):
    if not t.get("bundleManifest"):
        continue
    input_var = ""
    bundle_path = os.path.join(mk, t["bundleManifest"])
    try:
        b = json.load(open(bundle_path))
        input_var = b.get("installSurface", {}).get("inputVariable", "") or ""
    except FileNotFoundError:
        pass
    print("|".join([
        t.get("exampleRoot", ""),
        input_var,
        t.get("installSurfaceOutput", "") or "",
        t.get("deploySurfaceOutput", "") or "",
    ]))
' "${MARKET}")

assert_deploy_secret_ref \
  "examples/aws-serverless" \
  "admin_password" \
  "module.honua.admin_password_secret_arn"

if [ "$nonconforming" -ne 0 ]; then
  echo "Marketplace contract-conformance check FAILED." >&2
  exit 1
fi

echo "Marketplace manifest paths OK."
echo "Marketplace contract conformance OK."

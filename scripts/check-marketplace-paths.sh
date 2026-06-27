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

echo "Marketplace manifest paths OK."

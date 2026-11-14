#!/usr/bin/env bash
set -euo pipefail
sdk_version=${1:?SDK version required}
install_dir=${2:?Install directory required}
[[ "$sdk_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || exit 2
mkdir -p "$install_dir"
# All lane/bootstrap SDK installs serialize against the same destination lock.
exec 9>"$install_dir/.honua-sdk-install.lock"
flock 9
sdk_complete() {
  python3 - "${1:-$install_dir}" "$sdk_version" <<'PY'
import json
import re
from pathlib import Path
import sys
root, version = Path(sys.argv[1]), sys.argv[2]
major, minor, patch = version.split('.')
band = f'{major}.{minor}.{int(patch) // 100 * 100}'
sets = list((root / 'sdk-manifests' / band / 'workloadsets').glob('*/microsoft.net.workloads.workloadset.json'))
def manifest_object(path):
    # SDK manifests use JSON with comments and trailing commas. Keep string
    # literals intact, including URLs and comment-like text inside descriptions.
    literal = r'"(?:\\.|[^"\\])*"'
    content = re.sub(literal + r'|//[^\n]*|/\*.*?\*/',
                     lambda m: m[0] if m[0].startswith('"') else ' ',
                     path.read_text(encoding='utf-8-sig'), flags=re.S)
    content = re.sub(literal + r'|,\s*(?=[}\]])',
                     lambda m: m[0] if m[0].startswith('"') else '', content)
    return isinstance(json.loads(content), dict)
try:
    complete = (root / 'dotnet').is_file() and (root / 'sdk' / version / 'dotnet.dll').is_file()
    inventory = json.loads((root / '.honua-sdk-manifests' / f'{version}.json').read_text())
    complete &= isinstance(inventory, list) and bool(inventory)
    for relative in inventory:
        path = Path(relative)
        if path.is_absolute() or '..' in path.parts or path.parts[0] != 'sdk-manifests':
            sys.exit(1)
        complete &= manifest_object(root / path)
    for workload_set in sets:
        for name, reference in json.loads(workload_set.read_text()).items():
            manifest_version, feature_band = reference.split('/')
            manifest = root / 'sdk-manifests' / feature_band / name.lower() / manifest_version / 'WorkloadManifest.json'
            complete &= manifest_object(manifest)
    sys.exit(0 if complete else 1)
except (OSError, ValueError, TypeError):
    sys.exit(1)
PY
}
sdk_complete && exit 0
# A populated sdk/ directory can coexist with missing workload manifests. Install
# to staging so dotnet-install cannot mistake that partial SDK for a complete one.
staging=$(mktemp -d "$install_dir/.sdk-stage.XXXXXX")
trap 'rm -rf "${staging:?}"' EXIT
curl -fsSL --retry 5 --retry-all-errors https://dot.net/v1/dotnet-install.sh -o "$staging/install.sh"
bash "$staging/install.sh" --version "$sdk_version" --install-dir "$staging/sdk" --no-path
# Record the archive's own manifest layout: stock SDKs can ship loose manifests
# in an earlier feature band and need not contain a workload set at all.
python3 - "$staging/sdk" "$sdk_version" <<'PYINVENTORY'
import json
from pathlib import Path
import sys
root, version = Path(sys.argv[1]), sys.argv[2]
inventory = sorted(str(p.relative_to(root)) for p in
                   (root / 'sdk-manifests').rglob('WorkloadManifest.json'))
receipt = root / '.honua-sdk-manifests' / f'{version}.json'
receipt.parent.mkdir(parents=True, exist_ok=True)
receipt.write_text(json.dumps(inventory))
PYINVENTORY
sdk_complete "$staging/sdk" || { echo "Downloaded SDK $sdk_version is incomplete" >&2; exit 1; }
# Preserve files in use by running builds; fill missing versioned files only.
cp -an "$staging/sdk/." "$install_dir/"
sdk_complete || { echo "SDK $sdk_version remains incomplete in $install_dir" >&2; exit 1; }

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
  python3 - "$install_dir" "$sdk_version" <<'PY'
import json
from pathlib import Path
import sys
root, version = Path(sys.argv[1]), sys.argv[2]
major, minor, patch = version.split('.')
band = f'{major}.{minor}.{int(patch) // 100 * 100}'
manifest_root = root / 'sdk-manifests' / band
sets = list((manifest_root / 'workloadsets').glob('*/microsoft.net.workloads.workloadset.json'))
try:
    complete = (root / 'dotnet').is_file() and (root / 'sdk' / version / 'dotnet.dll').is_file()
    complete &= bool(sets) and bool(list(manifest_root.glob('*/*/WorkloadManifest.json')))
    for workload_set in sets:
        for name, reference in json.loads(workload_set.read_text()).items():
            manifest_version, feature_band = reference.split('/')
            complete &= (root / 'sdk-manifests' / feature_band / name.lower() / manifest_version / 'WorkloadManifest.json').is_file()
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
# Preserve files in use by running builds; fill missing versioned files only.
cp -an "$staging/sdk/." "$install_dir/"
sdk_complete || { echo "SDK $sdk_version remains incomplete in $install_dir" >&2; exit 1; }

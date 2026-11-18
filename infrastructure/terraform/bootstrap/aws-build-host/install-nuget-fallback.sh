# Appended after install-gate-runner.sh: the runners' read-only NuGet fallback folder.
# See "Shared NuGet fallback folder" in the README for the trust model.
fill_user=honua-nuget-fill
fallback_root=/var/lib/honua-nuget-fallback
id -u "$fill_user" > /dev/null 2>&1 ||
  useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin "$fill_user"
install -d -o root -g root -m 0755 "$fallback_root"
install -d -o "$fill_user" -g "$fill_user" -m 0700 "${fallback_root}/staging"
fill_min_free_gib=$(( $(jq -r .min_free_disk_gib /etc/honua-gate-runner.json) + 20 ))

fill_file="$(mktemp /usr/local/sbin/.honua-nuget-fallback-fill.XXXXXX)"
cat > "$fill_file" <<'FILL'
#!/bin/bash
# Runs as honua-nuget-fill; names the generation to publish in staging/generation.
set -euo pipefail
root="${HONUA_NUGET_FALLBACK_ROOT:-/var/lib/honua-nuget-fallback}"
staging="${root}/staging"
find "$staging" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
free_gib="$(df -BG --output=avail "$root" | tail -1 | tr -dc 0-9)"
if (( free_gib < ${HONUA_FILL_MIN_FREE_GIB:?} )); then
  echo "Only ${free_gib} GiB free; not filling." >&2
  exit 0
fi
work="$(mktemp -d "${staging}/.work.XXXXXX")"
trap 'rm -rf "$work"' EXIT
git clone --quiet --depth 1 --branch trunk https://github.com/honua-io/honua-server.git "$work/src"
cd "$work/src"
generation="gen-$(git ls-files -s -- '*.csproj' '*.props' '*.targets' NuGet.config global.json |
  sha256sum | cut -c1-16)"
if [[ -d "${root}/${generation}" ]]; then
  echo "$generation" > "${staging}/generation"
  exit 0
fi
export HOME="${work}/home" DOTNET_CLI_HOME="${work}/home" DOTNET_ROOT="${work}/dotnet" \
  PATH="${work}/dotnet:${PATH}" DOTNET_NOLOGO=1 DOTNET_CLI_TELEMETRY_OPTOUT=1 \
  NUGET_PACKAGES="${work}/packages" NUGET_HTTP_CACHE_PATH="${work}/http"
ensure-dotnet-sdk "$(jq -r .sdk.version global.json)" "${work}/dotnet"
# Keeps the repository's source mapping; GitHub Packages ids fail here and jobs fetch them.
dotnet restore Honua.sln -p:Configuration=Release > "${work}/restore.log" 2>&1 || true
if [[ ! -d "${work}/packages" ]]; then
  tail -20 "${work}/restore.log" >&2
  exit 1
fi
# Never shadow a Honua package; drop incomplete versions (NuGet writes .nupkg.metadata last).
find "${work}/packages" -mindepth 1 -maxdepth 1 -iname 'honua.*' -exec rm -rf {} +
find "${work}/packages" -mindepth 2 -maxdepth 2 -type d \
  ! -exec test -e '{}/.nupkg.metadata' ';' -exec rm -rf {} +
find "${work}/packages" -mindepth 1 -maxdepth 1 -type d -empty -delete
count() { { find "$1" -mindepth 3 -maxdepth 3 -name .nupkg.metadata 2> /dev/null || true; } | wc -l; }
packages="$(count "${work}/packages")"
# A feed outage must not publish a thin generation that unchanged inputs would keep.
floor="$(( $(count "${root}/current/") * 9 / 10 ))"
if (( packages < 100 || packages < floor )); then
  echo "Only ${packages} packages (floor ${floor}); keeping the current generation." >&2
  tail -20 "${work}/restore.log" >&2
  exit 1
fi
mv -T "${work}/packages" "${staging}/${generation}"
echo "$generation" > "${staging}/generation"
echo "Filled ${generation} with ${packages} packages."
FILL
chmod 0755 "$fill_file"
mv -f "$fill_file" /usr/local/sbin/honua-nuget-fallback-fill

publish_file="$(mktemp /usr/local/sbin/.honua-nuget-fallback-publish.XXXXXX)"
cat > "$publish_file" <<'PUBLISH'
#!/bin/bash
# Root, after the fill unit's processes are gone: move the staged tree out of the fill
# account's reach, check it, publish it root-owned and read-only, keep one previous.
set -euo pipefail
[[ "${SERVICE_RESULT:-success}" == success ]] || exit 0
pkill -KILL -u honua-nuget-fill || true
root="${HONUA_NUGET_FALLBACK_ROOT:-/var/lib/honua-nuget-fallback}"
staging="${root}/staging"
incoming="${root}/.incoming"
rm -rf "$incoming"
install -d -m 0700 "$incoming"
[[ -f "${staging}/generation" && ! -L "${staging}/generation" ]] || exit 0
generation="$(head -c 32 "${staging}/generation" | tr -d '\n')"
rm -f "${staging}/generation"
[[ "$generation" =~ ^gen-[0-9a-f]{16}$ ]] || { echo "Ignoring an invalid staged generation name." >&2; exit 1; }
if [[ -e "${staging}/${generation}" || -L "${staging}/${generation}" ]] && [[ ! -e "${root}/${generation}" ]]; then
  mv -T "${staging}/${generation}" "${incoming}/${generation}"
  staged="${incoming}/${generation}"
  if [[ -L "$staged" || ! -d "$staged" || -n "$(find -P "$staged" \( ! -type f ! -type d \) -o -links +1 ! -type d -o -ipath "$staged/honua.*" | head -1)" ]]; then
    echo "Refusing ${generation}: links, special files or Honua ids." >&2
    exit 1
  fi
  chown -R -P root:root "$staged"
  chmod -R a-w,a+rX "$staged"
  mv -T "$staged" "${root}/${generation}"
fi
[[ -d "${root}/${generation}" && "$(stat -c %u "${root}/${generation}")" == 0 ]] || exit 0
touch "${root}/${generation}"
ln -sfn "$generation" "${root}/.current"
mv -T "${root}/.current" "${root}/current"
for old in $(cd "$root" && ls -1dt gen-* | tail -n +3); do
  rm -rf "${root:?}/${old}"
done
PUBLISH
chmod 0700 "$publish_file"
mv -f "$publish_file" /usr/local/sbin/honua-nuget-fallback-publish

cat > /etc/systemd/system/honua-nuget-fallback-fill.service <<SERVICE
[Unit]
Description=Fill the runners' NuGet fallback folder
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
User=honua-nuget-fill
Environment=HONUA_FILL_MIN_FREE_GIB=${fill_min_free_gib}
ExecStart=/usr/local/sbin/honua-nuget-fallback-fill
ExecStopPost=+/usr/local/sbin/honua-nuget-fallback-publish
TimeoutStartSec=1h
Nice=10
IOSchedulingClass=idle
CPUQuota=400%
MemoryMax=8G
UMask=0022
IPAddressDeny=169.254.0.0/16 fd00:ec2::254/128
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
ReadWritePaths=/var/lib/honua-nuget-fallback/staging
SERVICE

cat > /etc/systemd/system/honua-nuget-fallback-fill.timer <<'TIMER'
[Unit]
Description=Fill the runners' NuGet fallback folder

[Timer]
OnBootSec=2min
OnUnitActiveSec=2h

[Install]
WantedBy=timers.target
TIMER
systemctl daemon-reload
systemctl enable --now honua-nuget-fallback-fill.timer

# Appended after shared/install-docker.sh, which defines apt_retry and sets strict mode.
apt_retry install -y git rsync python3 python3-venv unzip jq libfontconfig1 fonts-dejavu-core libatomic1 xmlstarlet skopeo clang zlib1g-dev
# Chromium's system libraries, so browser tests (Playwright) run on the host.
apt_retry install -y libasound2t64 libatk-bridge2.0-0t64 libatk1.0-0t64 libatspi2.0-0t64 libcairo2 libcups2t64 libdbus-1-3 libdrm2 libgbm1 libglib2.0-0t64 libnspr4 libnss3 libpango-1.0-0 libx11-6 libxcb1 libxcomposite1 libxdamage1 libxext6 libxfixes3 libxkbcommon0 libxrandr2
sudo -u ubuntu /usr/local/bin/ensure-dotnet-sdk 10.0.404 /home/ubuntu/.dotnet
sudo -u ubuntu /usr/local/bin/ensure-dotnet-sdk 11.0.100 /home/ubuntu/.dotnet
echo 'export PATH=/home/ubuntu/.dotnet:$PATH DOTNET_ROOT=/home/ubuntu/.dotnet DOTNET_CLI_TELEMETRY_OPTOUT=1' > /etc/profile.d/dotnet.sh
curl -fsSL --retry 5 --retry-all-errors https://deb.nodesource.com/setup_22.x | bash -
apt_retry install -y nodejs

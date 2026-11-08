#!/bin/bash
# lib/provision-lxc.sh - base setup inside a new game LXC (Debian or Ubuntu), run as root by install.sh:
#   pct exec <CTID> -- bash -s < provision-lxc.sh
# Installs the base tools and Docker from Docker's own apt repository (docker-ce + compose plugin).
# Safe to run again: steps that are already done are skipped. No community-scripts are used.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

step() { printf '\n--- %s\n' "$*"; }

. /etc/os-release
case "$ID" in
  debian|ubuntu) ;;
  *) echo "Unsupported OS: $ID (only debian and ubuntu)"; exit 1 ;;
esac

step "Wait for network"
for _ in $(seq 1 30)
do
  getent hosts deb.debian.org > /dev/null 2>&1 && break
  sleep 2
done
getent hosts deb.debian.org > /dev/null 2>&1 || { echo "No DNS/network in the LXC after 60 s."; exit 1; }

step "Base packages"
apt-get update -qq
apt-get install -y -qq ca-certificates curl gnupg nano python3 git > /dev/null

step "Docker (download.docker.com)"
if ! command -v docker > /dev/null 2>&1 || ! docker compose version > /dev/null 2>&1
then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "https://download.docker.com/linux/$ID/gpg" -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/$ID $VERSION_CODENAME stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin > /dev/null
fi
systemctl enable --now docker > /dev/null 2>&1
docker version --format 'Docker {{.Server.Version}}'
docker compose version

step "Done"

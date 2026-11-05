#!/bin/bash
# tests/sandbox.sh WORKDIR SCRIPT
# Runs SCRIPT as root in a private mount namespace with overlays on /etc /root /usr/local /opt /var,
# so a test can install the commands and edit startup files without touching the real system.
# All writes land in WORKDIR. Needs root (or sudo) and overlayfs.
set -e
B=$(readlink -f "$1"); SCRIPT=$(readlink -f "$2")
mkdir -p "$B"
exec unshare -m --propagation private bash -c '
set -e
for d in etc root usr/local opt var; do
  k=${d//\//_}
  mkdir -p "'"$B"'/$k/u" "'"$B"'/$k/w"
  mount -t overlay overlay -o lowerdir=/$d,upperdir="'"$B"'/$k/u",workdir="'"$B"'/$k/w" /$d
done
mkdir -p "'"$B"'/run"; mount --bind "'"$B"'/run" /run
set +e
cd /root
exec bash "'"$SCRIPT"'"
'

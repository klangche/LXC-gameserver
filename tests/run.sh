#!/bin/bash
# tests/run.sh: runs all tests in throwaway sandboxes (needs root and overlayfs; on CI via sudo).
# Tests the working tree as it is now, including uncommitted files.
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d /tmp/gs-tests.XXXXXX)
# Bare repo med arbetskatalogen som main (update-lxc testas mot den)
mkdir "$T/src"
(cd "$REPO" && git ls-files -co --exclude-standard -z | xargs -0 cp --parents -t "$T/src")
git -C "$T/src" init -q -b main
git -C "$T/src" add -A
git -C "$T/src" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -qm "version under test"
git clone -q --bare "$T/src" "$T/bare.git"
export REPO BARE="$T/bare.git"
RC=0
for t in "$REPO"/tests/test-*.sh
do
  echo "=== $(basename "$t")"
  "$REPO/tests/sandbox.sh" "$T/sb-$(basename "$t" .sh)" "$t" || RC=1
  echo
done
echo "Sandboxes and logs: $T"
exit "$RC"

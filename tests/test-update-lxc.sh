#!/bin/bash
# update-lxc on a legacy LXC: bootstrap, normal updates, blocked cases, failure + rollback.
# Needs $BARE: a bare repo whose main is the version under test (tests/run.sh makes it).
. "$REPO/tests/lib.sh"
legacy_setup
cp -r "$BARE" /root/bare.git
printf 'REPO_URL=file:///root/bare.git\nREPO_BRANCH=main\nREPO_DIR=/opt/lxc-gameserver\nBACKUP_ROOT=/var/backups/gameserver\n' > /etc/gameserver-repo.conf
data_snapshot > /tmp/data.before
U() { update-lxc --yes "$@" > /tmp/u.log 2>&1; echo $?; }

git clone -q file:///root/bare.git /opt/lxc-gameserver
check "bootstrap dry run blocks on unknown local versions" 2 "$(bash /opt/lxc-gameserver/lib/update-lxc.sh --dry-run > /tmp/u.log 2>&1; echo $?)"
check "dry run shows the local compose change" 1 "$(grep -c '^      -      - SERVER_SLOTS=8' /tmp/u.log)"
check "dry run made no backup" 0 "$(ls /var/backups/gameserver 2>/dev/null | wc -l)"
check "bootstrap --force" 0 "$(bash /opt/lxc-gameserver/lib/update-lxc.sh --force --yes > /tmp/u.log 2>&1; echo $?)"
check "local compose version kept as .local-*" 1 "$(grep -l SERVER_SLOTS=8 /opt/enshrouded/docker-compose.yml.local-* | wc -l)"
BK=$(cat /var/lib/gameserver/last-update-backup)
sha256sum /etc/gameserver-autoupdate.conf /etc/gameserver.conf > /tmp/settings.md5
check "backup checksums verify" 0 "$(cd "$BK" && sha256sum --quiet -c SHA256SUMS; echo $?)"
check "backup holds the savegame" 1 "$(tar -tzf "$BK/gamedata.tar.gz" | grep -c '^game/savegame/3ad85aea$')"
check "backup keeps the symlink" 1 "$(tar -tvzf "$BK/gamedata.tar.gz" | grep -c 'latest -> 3ad85aea')"
check "backup holds passwords.env" 1 "$(tar -tzf "$BK/config.tar.gz" | grep -c 'opt/enshrouded/passwords.env')"
check "second run: up to date" "0 1" "$(U) $(grep -c 'Already up to date' /tmp/u.log)"

git clone -q file:///root/bare.git /root/work
commit() { git -C /root/work -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -qam "$1" && git -C /root/work push -q origin HEAD:main; }
revert() { git -C /root/work -c user.email=t@t -c user.name=t -c commit.gpgsign=false revert --no-edit HEAD > /dev/null && git -C /root/work push -q origin HEAD:main; }

sed -i 's/SERVER_SLOTS=16/SERVER_SLOTS=12/' /root/work/games/enshrouded/docker-compose.yml; commit "slots 12"
check "dry run of a normal update" "0 1" "$(U --dry-run) $(grep -c 'will be updated' /tmp/u.log)"
: > /var/log/fake-docker.log
check "normal update" 0 "$(U)"
check "compose updated" 1 "$(grep -c SERVER_SLOTS=12 /opt/enshrouded/docker-compose.yml)"
check "server stopped for backup and started" "1 1" "$(grep -c 'compose stop' /var/log/fake-docker.log) $(grep -c 'compose up -d' /var/log/fake-docker.log)"

sed -i 's/start the game server|/start the game server (v2)|/' /root/work/lib/common.sh
(cd /root/work && python3 tools/build-commands.py > /dev/null); commit "help text"
: > /var/log/fake-docker.log
check "scripts-only update" 0 "$(U)"
check "scripts-only update: no restart" 0 "$(grep -c 'compose stop\|compose up' /var/log/fake-docker.log)"
check "new commands active" 1 "$(server-help | grep -c '^  start .*(v2)')"

sed -i 's/SERVER_SLOTS=12/SERVER_SLOTS=4/' /opt/enshrouded/docker-compose.yml
sed -i 's/SERVER_SLOTS=12/SERVER_SLOTS=10/' /root/work/games/enshrouded/docker-compose.yml; commit "slots 10"
check "local edit blocks the update" 2 "$(U)"
check "local edit untouched" 1 "$(grep -c SERVER_SLOTS=4 /opt/enshrouded/docker-compose.yml)"
sed -i 's/SERVER_SLOTS=4/SERVER_SLOTS=12/' /opt/enshrouded/docker-compose.yml
check "update after undoing the local edit" 0 "$(U)"

echo "# my tweak" >> /usr/local/lib/gameserver/common.sh
sed -i 's/SERVER_SLOTS=10/SERVER_SLOTS=11/' /root/work/games/enshrouded/docker-compose.yml; commit "slots 11"
check "hand-edited generated file blocks" "2 1" "$(U) $(grep -c 'common.sh: FAILED' /tmp/u.log)"
sed -i '/# my tweak/d' /usr/local/lib/gameserver/common.sh

sed -i 's#./game:/opt/enshrouded#./gamedata:/opt/enshrouded#' /root/work/games/enshrouded/docker-compose.yml; commit "move volume"
check "volume change = data migration, blocked" "2 1" "$(U) $(grep -c 'GAME DATA MIGRATION' /tmp/u.log)"
revert

cp /opt/enshrouded/docker-compose.yml /tmp/compose.before
REV=$(git -C /opt/lxc-gameserver rev-parse HEAD)
python3 - <<'P'
p = '/root/work/games/enshrouded/install-server-commands.sh'
s = open(p).read().replace('mkdir -p "$LIB_DIR" "$STATE_DIR"\n', 'mkdir -p "$LIB_DIR" "$STATE_DIR"\ntouch $LIB_DIR/leftover\necho SIMULATED FAILURE; exit 1\n', 1)
open(p, 'w').write(s)
P
sed -i 's/SERVER_SLOTS=11/SERVER_SLOTS=9/' /root/work/games/enshrouded/docker-compose.yml; commit "broken installer"
check "failed update rolls back (exit 3)" 3 "$(U)"
check "compose restored" 0 "$(cmp -s /tmp/compose.before /opt/enshrouded/docker-compose.yml; echo $?)"
check "files from the failed update removed" no "$([ -e /usr/local/lib/gameserver/leftover ] && echo yes || echo no)"
check "clone back at the previous version" "$REV" "$(git -C /opt/lxc-gameserver rev-parse HEAD)"
check "server running again" true "$(cat /run/fake-running)"
check "no in-progress marker" no "$([ -e /var/lib/gameserver/update.inprogress ] && echo yes || echo no)"
revert
check "update after the upstream fix" 0 "$(U)"

git -C /opt/lxc-gameserver checkout -q -b other
check "other branch refused" 2 "$(U)"
git -C /opt/lxc-gameserver checkout -q main
git -C /opt/lxc-gameserver remote set-url origin https://example.com/other.git
check "other remote refused" 2 "$(U)"
git -C /opt/lxc-gameserver remote set-url origin file:///root/bare.git
echo dirty >> /opt/lxc-gameserver/README.md
check "dirty clone refused" 2 "$(U)"
git -C /opt/lxc-gameserver checkout -q README.md
sed -i 's#^REPO_URL=.*#REPO_URL=file:///root/nope.git#' /etc/gameserver-repo.conf
check "unreachable remote: error, nothing changed" 1 "$(U)"
sed -i 's#^REPO_URL=.*#REPO_URL=file:///root/bare.git#' /etc/gameserver-repo.conf

check "--rollback" 0 "$(U --rollback)"
check "--rollback restored the previous compose" 1 "$(grep -c SERVER_SLOTS=10 /opt/enshrouded/docker-compose.yml)"

check "settings files unchanged by later updates" 0 "$(sha256sum --quiet -c /tmp/settings.md5 > /dev/null 2>&1; echo $?)"
data_snapshot > /tmp/data.after
check "game data, secrets, settings identical after everything" "" "$(diff /tmp/data.before /tmp/data.after)"
done_tests

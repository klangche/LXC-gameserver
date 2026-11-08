#!/bin/bash
# An LXC on the first update-lxc release (commands without the gameserver- prefix) updates to this
# version. The old update-lxc cannot know the new names, so its final check fails and it rolls
# back; the documented one-time step (run update-lxc.sh from the clone) then completes it.
. "$REPO/tests/lib.sh"
install -m 755 "$REPO/tests/fake-docker" /usr/local/bin/docker
mkdir -p /opt/enshrouded/game/savegame
echo world1 > /opt/enshrouded/game/savegame/3ad85aea
cp "$REPO/games/enshrouded/docker-compose.yml" /opt/enshrouded/docker-compose.yml
cp "$REPO/tests/fixtures/release1-install-server-commands.sh" /opt/enshrouded/install-server-commands.sh
printf 'SERVER_ROLE_0_PASSWORD=abcde1\nSERVER_ROLE_1_PASSWORD=abcde2\nSERVER_ROLE_2_PASSWORD=abcde3\n' > /opt/enshrouded/passwords.env
printf 'SERVER_NAME=gameserver-enshrouded-test\nWORLD_NAME=test\n' > /opt/enshrouded/.env
bash /opt/enshrouded/install-server-commands.sh enshrouded --record-deployed > /dev/null 2>&1
cp -r "$BARE" /root/bare.git
printf 'REPO_URL=file:///root/bare.git\nREPO_BRANCH=main\nREPO_DIR=/opt/lxc-gameserver\nBACKUP_ROOT=/var/backups/gameserver\n' > /etc/gameserver-repo.conf
data_snapshot > /tmp/data.before
check "release 1: old command update-lxc exists" /usr/local/bin/update-lxc "$(type -P update-lxc)"

update-lxc --yes > /tmp/u1.log 2>&1
check "old update-lxc: verification fails and rolls back (exit 3)" 3 "$?"
hash -r
check "after the rollback the old commands are back" "/usr/local/bin/update-lxc /usr/local/bin/start" "$(type -P update-lxc) $(type -P start)"
# Den gamla versionens återställning känner inte till de nya namnen: gameserver-*-stubbarna blir kvar
# (de fungerar med den återställda common.sh) tills steget nedan städar.
check "after the rollback the server still runs" true "$(cat /run/fake-running 2>/dev/null || echo true)"
check "data intact after the failed old update" "" "$(data_snapshot | diff /tmp/data.before -)"

git -C /opt/lxc-gameserver pull -q --ff-only
bash /opt/lxc-gameserver/lib/update-lxc.sh --yes > /tmp/u2.log 2>&1
check "one-time step: update-lxc.sh from the clone" 0 "$?"
hash -r
check "new commands installed" /usr/local/bin/gameserver-update-lxc "$(type -P gameserver-update-lxc)"
check "old short commands removed" "" "$(type -P update-lxc)$(type -P start)$(type -P server-help)"
check "data intact" "" "$(data_snapshot | diff /tmp/data.before -)"
gameserver-update-lxc --yes > /tmp/u3.log 2>&1
check "next run: up to date" "0 1" "$? $(grep -c 'Already up to date' /tmp/u3.log)"
done_tests

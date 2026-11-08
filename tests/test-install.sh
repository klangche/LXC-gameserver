#!/bin/bash
# Fresh install with install.sh on a fake Proxmox host. The community-scripts Docker helper is replaced
# by tests/fake-pve/docker-helper.sh (it records what it gets and installs its own /usr/bin/update);
# the in-LXC part (install-server-commands.sh) really runs in the sandbox.
. "$REPO/tests/lib.sh"
install -m 755 "$REPO/tests/fake-docker" /usr/local/bin/docker
for f in pct pvesh; do install -m 755 "$REPO/tests/fake-pve/$f" "/usr/local/bin/$f"; done

check "install.sh runs the vanilla community-scripts Docker helper by default" 1 \
  "$(grep -c '^DOCKER_HELPER="${DOCKER_HELPER:-https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/docker.sh}"$' "$REPO/install.sh")"
check "the helper is run as published (bash -c of the downloaded script)" 1 "$(grep -c 'bash -c "$(curl -fsSL "$DOCKER_HELPER")"' "$REPO/install.sh")"

OUT=$(printf '\n' | var_game=valheim var_servername="Friends" var_mcp=no \
  GS_RAW="file://$REPO" GS_API="file:///nonexistent" DOCKER_HELPER="file://$REPO/tests/fake-pve/docker-helper.sh" \
  bash "$REPO/install.sh" 2>&1)
check "install.sh exit code" 0 "$?"
echo "$OUT" | tail -n 2
check "helper got the game's settings" "var_cpu=4 var_ctid=105 var_disk=20 var_hostname=gameserver-valheim-friends var_os=debian var_ram=4096" \
  "$(grep -E '^var_(cpu|ctid|disk|hostname|os|ram)=' /var/log/fake-helper.env | tr '\n' ' ' | sed 's/ $//')"
md5sum /usr/bin/update > /tmp/helper-update.md5
check "passwords.env: 600 with a 16-character generated password" "600 1" "$(stat -c %a /opt/valheim/passwords.env) $(grep -cE '^SERVER_PASS=[A-Za-z0-9]{16}$' /opt/valheim/passwords.env)"
check ".env" "SERVER_NAME=gameserver-valheim-friends" "$(head -n1 /opt/valheim/.env)"
check "gameserver.conf written" 1 "$(grep -c '^GAME=valheim' /etc/gameserver.conf)"
check "deployed manifest recorded" 2 "$(wc -l < /var/lib/gameserver/deployed.sha256)"
check "server started (docker compose up)" 1 "$(grep -c 'compose up -d' /var/log/fake-docker.log)"
for N in gameserver-status gameserver-start gameserver-update gameserver-update-lxc gameserver-check gameserver-help gameserver-auto-update gameserver-password gameserver-passwords lxc-gameserver-help
do
  check "command $N" "/usr/local/bin/$N" "$(type -P "$N")"
done
for N in start stop status server-help update-lxc
do
  check "no short command $N" "" "$(type -P "$N")"
done
check "the helper's own update command is what 'update' runs" "/usr/bin/update community-scripts updater" "$(type -P update) $(update)"
check "list shown once in a new shell" 1 "$(echo exit | bash -i 2>/dev/null | banners)"
gameserver-check > /tmp/check.log 2>&1
check "gameserver-check passes, helper file only as INFO" "0 1" "$? $(grep -c 'INFO    /usr/bin/update belongs to the Proxmox VE community-scripts helper' /tmp/check.log)"
bash /opt/valheim/install-server-commands.sh valheim > /dev/null 2>&1
check "the helper's /usr/bin/update is unchanged after a re-install" 0 "$(md5sum --quiet -c /tmp/helper-update.md5 > /dev/null 2>&1; echo $?)"
[ "$FAILS" = 0 ] || cat /tmp/check.log
done_tests

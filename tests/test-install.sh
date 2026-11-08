#!/bin/bash
# Fresh install with install.sh on a fake Proxmox host (fake pct/pveam/pvesm/pvesh, files from the
# working tree via file://). The in-LXC part (install-server-commands.sh) really runs in the sandbox.
. "$REPO/tests/lib.sh"
install -m 755 "$REPO/tests/fake-docker" /usr/local/bin/docker
for f in pct pvesh pveam pvesm; do install -m 755 "$REPO/tests/fake-pve/$f" "/usr/local/bin/$f"; done
OUT=$(printf '\n' | var_game=valheim var_servername="Friends" var_yes=yes var_mcp=no \
  GS_RAW="file://$REPO" GS_API="file:///nonexistent" bash "$REPO/install.sh" 2>&1)
check "install.sh exit code" 0 "$?"
echo "$OUT" | tail -n 3
L=/var/log/fake-pve.log
check "install.sh code has no community-scripts" 0 "$(grep -v '^[[:space:]]*#' "$REPO/install.sh" | grep -c community-scripts)"
check "picked newest debian 12 template" 1 "$(grep -c 'pveam download local debian-12-standard_12.7-1_amd64.tar.zst' $L)"
CREATE=$(grep '^pct create' $L)
check "pct create: CT id, template, hostname" 1 "$(echo "$CREATE" | grep -c 'pct create 105 local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst --hostname gameserver-valheim-friends')"
check "pct create: unprivileged + nesting/keyctl for Docker" 1 "$(echo "$CREATE" | grep -c -- '--unprivileged 1 --features nesting=1,keyctl=1')"
check "pct create: resources from game.conf" 1 "$(echo "$CREATE" | grep -c -- '--cores 4 --memory 4096 --swap 512 --rootfs local-lvm:20')"
check "pct create: dhcp on vmbr0, onboot" 1 "$(echo "$CREATE" | grep -c -- '--net0 name=eth0,bridge=vmbr0,ip=dhcp .*--onboot 1')"
check "provisioning script was sent" 1 "$(echo "$OUT" | grep -c 'provision-lxc.sh received, syntax ok')"
check "passwords.env: 600 with a generated password" "600 1" "$(stat -c %a /opt/valheim/passwords.env) $(grep -cE '^SERVER_PASS=[A-Za-z0-9]{16}$' /opt/valheim/passwords.env)"
check ".env" "SERVER_NAME=gameserver-valheim-friends" "$(head -n1 /opt/valheim/.env)"
check "gameserver.conf written" 1 "$(grep -c '^GAME=valheim' /etc/gameserver.conf)"
check "deployed manifest recorded" 2 "$(wc -l < /var/lib/gameserver/deployed.sha256)"
check "server started (docker compose up)" 1 "$(grep -c 'compose up -d' /var/log/fake-docker.log)"
for N in gameserver-status gameserver-start gameserver-update gameserver-update-lxc gameserver-check gameserver-help gameserver-auto-update gameserver-password
do
  check "command $N" "/usr/local/bin/$N" "$(type -P "$N")"
done
for N in start stop update status server-help update-lxc
do
  check "no short command $N" "" "$(type -P "$N")"
done
check "list shown once in a new shell" 1 "$(echo exit | bash -i 2>/dev/null | banners)"
gameserver-check > /tmp/check.log 2>&1
check "gameserver-check clean on a fresh install" 0 "$?"
[ "$FAILS" = 0 ] || cat /tmp/check.log
done_tests

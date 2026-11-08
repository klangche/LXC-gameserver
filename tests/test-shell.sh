#!/bin/bash
# Shell startup + command conflicts on a legacy LXC after the new installer (runs in tests/sandbox.sh)
. "$REPO/tests/lib.sh"
legacy_setup

check "legacy: two different command lists at start" 2 "$(echo exit | bash -i 2>/dev/null | grep -cE ' commands \(|^Commands:')"
check "legacy: update is an alias" alias "$(echo 'type -t update; exit' | bash -i 2>/dev/null | tail -1)"
check "legacy: help is an alias" alias "$(echo 'type -t help; exit' | bash -i 2>/dev/null | tail -1)"

bash "$REPO/games/enshrouded/install-server-commands.sh" enshrouded > /tmp/inst.log 2>&1
check "installer exit code" 0 "$?"
check "old GAMESERVER_COMMANDS block removed" 0 "$(grep -c GAMESERVER_COMMANDS /etc/bash.bashrc)"
check "old CUSTOM_CMDS block removed" 0 "$(grep -c CUSTOM_CMDS /etc/bash.bashrc)"
check "bash.bashrc backup made" 1 "$(ls /etc/bash.bashrc.bak-gameserver-* | wc -l)"
check "enshrouded-help neutralised, .bashrc valid" "0 1" "$(bash -n /root/.bashrc; echo -n "$? "; grep -c ': # enshrouded-help removed' /root/.bashrc)"
check "user alias 'update' left alone" 1 "$(grep -c "^alias update=" /root/.bashrc)"
server-check > /tmp/sc.log 2>&1
check "server-check reports the alias conflict" "1 1" "$? $(grep -c 'CONFLICT update: is an alias' /tmp/sc.log)"
sed -i "/^alias update=/d" /root/.bashrc
server-check > /tmp/sc.log 2>&1
check "server-check clean after removing the alias" 0 "$?"

check "interactive shell: list once" 1 "$(echo exit | bash -i 2>/dev/null | banners)"
check "login shell: list once" 1 "$(echo exit | bash -il 2>/dev/null | banners)"
check "re-sourcing startup files: still once" 1 "$(printf '. /etc/bash.bashrc\n. /etc/profile\n. /etc/profile.d/zz-gameserver.sh\nexit\n' | bash -i 2>/dev/null | banners)"
if command -v script > /dev/null
then
  check "pty: login + 2 nested bash = 3 lists" 3 "$( (sleep 1; echo bash; sleep 1; echo bash; sleep 1; echo '. /etc/bash.bashrc'; sleep 1; echo exit; echo exit; echo exit) | script -qc 'bash -il' /dev/null | banners)"
fi
check "bash -c / bash -lc silent" "" "$(bash -c true; bash -lc true)"
check "bash -ic 'cmd' prints only the output" hi "$(bash -ic 'echo hi' 2>/dev/null)"
OUT=$(bash -lc 'echo data; exit 7'); RC=$?
check "script output and exit code untouched" "data 7" "$OUT $RC"
check "GS_NO_BANNER=1 disables the list" 0 "$(echo exit | GS_NO_BANNER=1 bash -i 2>/dev/null | banners)"
check "help is the bash builtin again" builtin "$(echo 'type -t help; exit' | bash -i 2>/dev/null | tail -1)"
for N in status serverlog start stop restart update-game update versions backup password passwords lösenord logs auto-update update-lxc server-check server-help
do
  check "command $N is /usr/local/bin/$N" "/usr/local/bin/$N" "$(type -P "$N")"
done
check "update tells about update-game" 1 "$(grep -c 'update is now called update-game' /usr/local/bin/update)"
check "server-help --full shows examples" 14 "$(server-help --full | grep -c 'example:')"
md5sum /etc/bash.bashrc /root/.bashrc /etc/profile.d/zz-gameserver.sh > /tmp/rc.md5
bash "$REPO/games/enshrouded/install-server-commands.sh" enshrouded > /dev/null 2>&1
check "re-running the installer changes nothing" 0 "$(md5sum --quiet -c /tmp/rc.md5 > /dev/null 2>&1; echo $?)"
check "gameserver.conf got new keys, kept old" "1 1" "$(grep -c '^PLAYER_QUERY=a2s:15637' /etc/gameserver.conf) $(grep -c '^DIR=/opt/enshrouded' /etc/gameserver.conf)"
done_tests

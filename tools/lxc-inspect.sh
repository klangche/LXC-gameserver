#!/bin/bash
# tools/lxc-inspect.sh - READ-ONLY inventory of a game LXC, before a migration or update-lxc.
#
# Run inside the LXC as root:   bash lxc-inspect.sh
# It changes nothing. It only reads files and runs read-only commands (ls, stat, find,
# systemctl list/status, docker ps/inspect, git status/diff). Secret values are never
# printed: for passwords.env and .env only the variable names are shown.
# The report is written to /root/lxc-inspect-<time>.txt and also printed.

OUT=/root/lxc-inspect-$(date +%Y%m%d-%H%M%S).txt
# Testskal ska inte skriva till .bash_history, git ska inte uppdatera index-filen
export HISTFILE=/dev/null GIT_OPTIONAL_LOCKS=0
REPO_RAW=${REPO_RAW:-https://raw.githubusercontent.com/klangche/LXC-gameserver/main}

section() { printf '\n========== %s ==========\n' "$*"; }
run() { printf '\n$ %s\n' "$*"; "$@" 2>&1; printf '[exit %s]\n' "$?"; }
keys_only() { [ -f "$1" ] && sed -E 's/^([A-Za-z_][A-Za-z0-9_]*)=.*/\1=<hidden>/' "$1"; }

{
section "System"
run date -Is
run hostname
run cat /etc/os-release
run uname -a
run id
run df -hT /
run df -hT /opt /var /root
run free -m
run findmnt -R -o TARGET,SOURCE,FSTYPE,OPTIONS /
echo "\$SHELL=$SHELL BASH_VERSION=$BASH_VERSION"
run locale

section "Game server configuration (/etc/gameserver*.conf)"
for f in /etc/gameserver.conf /etc/gameserver-autoupdate.conf /etc/gameserver-repo.conf
do
  run ls -la "$f"
  [ -f "$f" ] && run cat "$f"
done
GAME=''
DIR=''
# shellcheck disable=SC1091
[ -f /etc/gameserver.conf ] && . /etc/gameserver.conf
echo "GAME=$GAME DIR=$DIR"

section "Game folders under /opt"
run ls -la /opt
for d in /opt/*/
do
  [ -d "$d" ] || continue
  run ls -la "$d"
  run du -sh "$d"
  run find "$d" -maxdepth 2 -printf '%M %u:%g %8s %TY-%Tm-%Td %p\n'
  run find "$d" -maxdepth 4 -type l -printf '%p -> %l\n'
done

if [ -n "$DIR" ] && [ -d "$DIR" ]
then
  section "Game folder $DIR in detail"
  for f in docker-compose.yml install-server-commands.sh
  do
    run sha256sum "$DIR/$f"
  done
  run cat "$DIR/docker-compose.yml"
  echo; echo "--- passwords.env (names only)"; keys_only "$DIR/passwords.env"
  echo; echo "--- .env (names only)"; keys_only "$DIR/.env"
  run stat -c '%n %a %U:%G' "$DIR/passwords.env" "$DIR/.env"
  run ls -la "$DIR/backups"
  echo; echo "--- savegame-like files (newest first)"
  find "$DIR" -xdev -type f \( -iname '*save*' -o -iname '*.db' -o -iname '*.fwl' -o -iname '*.sav' -o -iname 'level.dat' -o -iname '*.sqlite*' -o -iname '*.json' \) \
    -not -path "*/backups/*" -printf '%TY-%Tm-%Td %TH:%TM %10s %p\n' 2>/dev/null | sort -r | head -n 60
  echo; echo "--- compare with the repository (main)"
  for f in docker-compose.yml install-server-commands.sh
  do
    if curl -fsSL "$REPO_RAW/games/$GAME/$f" -o "/tmp/lxc-inspect-repo-$f" 2>/dev/null
    then
      if cmp -s "$DIR/$f" "/tmp/lxc-inspect-repo-$f"
      then
        echo "$f: identical to main"
      else
        echo "$f: DIFFERS from main:"
        diff -u --label "installed" --label "main" "$DIR/$f" "/tmp/lxc-inspect-repo-$f" | head -n 200
      fi
      rm -f "/tmp/lxc-inspect-repo-$f"
    else
      echo "$f: could not download from $REPO_RAW (no network?)"
    fi
  done
fi

section "Docker"
run docker version --format '{{.Server.Version}}'
run docker compose version
run docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'
for c in $(docker ps -a --format '{{.Names}}' 2>/dev/null)
do
  run docker inspect -f '{{.Name}} image={{.Config.Image}} restart={{.HostConfig.RestartPolicy.Name}} network={{.HostConfig.NetworkMode}} started={{.State.StartedAt}} restarts={{.RestartCount}}' "$c"
  run docker inspect -f '{{range .Mounts}}{{.Type}} {{.Source}} -> {{.Destination}} rw={{.RW}}{{println}}{{end}}' "$c"
  echo "--- last 20 log lines of $c"
  docker logs --tail 20 "$c" 2>&1
done
run docker volume ls
run docker images --format 'table {{.Repository}}:{{.Tag}}\t{{.ID}}\t{{.CreatedSince}}\t{{.Size}}'

section "Custom commands"
run ls -la /usr/local/bin /usr/local/sbin
run ls -la /usr/local/lib/gameserver
echo; echo "--- files from the Proxmox VE community-scripts helper (kept as they are)"
grep -lis 'community-scripts' /usr/bin/update /usr/local/bin/* /etc/profile.d/*.sh /etc/motd /etc/update-motd.d/* 2>/dev/null || echo "none found"
for f in /usr/local/bin/*
do
  [ -f "$f" ] || continue
  if head -c 2 "$f" | grep -q '#!'
  then
    echo "--- $f"
    head -n 15 "$f"
  fi
done
echo; echo "--- what an interactive root shell runs for each command name"
for n in gameserver-status gameserver-start gameserver-update gameserver-update-lxc gameserver-check gameserver-help \
  start stop restart status serverlog logs update update-game versions backup password passwords lösenord auto-update update-lxc server-check server-help help enshrouded-help
do
  printf '%-14s ' "$n"
  GS_NO_BANNER=1 bash -ic "echo __TYPE__; type -a '$n' 2>&1 | head -n 3 | tr '\n' ';'" 2>/dev/null < /dev/null | sed -n '/^__TYPE__$/,$p' | sed 1d
  echo
done

section "Shell startup files"
for f in /etc/profile /etc/bash.bashrc /etc/profile.d/*.sh /root/.bashrc /root/.bash_aliases /root/.profile /root/.bash_profile /root/.bash_login /etc/environment /etc/motd /etc/update-motd.d/*
do
  [ -e "$f" ] || continue
  echo
  echo "--- $f ($(stat -c '%a %U %y' "$f"))"
  bash -n "$f" 2>&1 | sed 's/^/SYNTAX: /'
  grep -nE 'alias |\(\) *\{|function |server-help|GAMESERVER|CUSTOM_CMDS|enshrouded|echo|printf|source |^\. ' "$f" 2>/dev/null | head -n 60
done
for f in /etc/bash.bashrc.bak* /root/.bashrc.bak*
do
  [ -e "$f" ] && echo "backup copy: $f"
done
echo; echo "--- how many times the list is printed"
echo "interactive:       $(echo exit | bash -i 2>/dev/null | grep -cE ' commands \(|Commands')"
echo "interactive login: $(echo exit | bash -il 2>/dev/null | grep -cE ' commands \(|Commands')"
echo "non-interactive output: [$(bash -c true 2>&1; bash -lc true 2>&1)]"
echo "errors at shell start:"
echo exit | bash -i 2>&1 >/dev/null | grep -vE 'job control|process group|^exit$|# exit$' | head -n 10

section "systemd and scheduled tasks"
run systemctl list-units --type=service --state=running --no-pager
run systemctl list-timers --all --no-pager
run systemctl status gameserver-autoupdate.timer --no-pager
run ls -la /etc/systemd/system
run crontab -l
run ls -la /etc/cron.d /etc/cron.daily /etc/cron.hourly /var/spool/cron/crontabs
run tail -n 20 /var/log/gameserver-autoupdate.log
run tail -n 20 /var/log/gameserver-update-lxc.log

section "Git"
for d in /opt/lxc-gameserver /root/LXC-gameserver /opt/*/.git
do
  d=${d%/.git}
  [ -d "$d/.git" ] || continue
  run git -C "$d" remote -v
  run git -C "$d" status --short --branch
  run git -C "$d" log -3 --oneline
done
run ls -la /var/lib/gameserver
run cat /var/lib/gameserver/deployed.rev

section "Tools"
for t in git python3 nano curl tar gzip sha256sum flock script
do
  printf '%-10s %s\n' "$t" "$(command -v "$t" || echo MISSING)"
done
} 2>&1 | tee "$OUT"

echo
echo "Report saved: $OUT  (secret values are not included)"

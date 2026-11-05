#!/bin/bash
# install-server-commands.sh for @@GAME@@
#
# GENERATED FILE - do not edit. Edit lib/ and games/<game>/profile.conf, then run:
#   python3 tools/build-commands.py
#
# Installerar samma serverkommandon på varje spel-LXC (se README "Commands"):
#   status, serverlog, start, stop, restart, update-game (gammalt namn: update), versions,
#   backup, password (passwords, lösenord), logs, auto-update, update-lxc, server-check, server-help
#
# Sätter INTE upp någon spelserver och rör aldrig speldata, passwords.env eller .env.
# Kan köras om: befintliga inställningar behålls, nya nycklar läggs till.
# Användning: install-server-commands.sh [SPEL] [--record-deployed]

set -e

if [ "$(id -u)" -ne 0 ]
then
  echo "Kör som root."
  exit 1
fi

CONF=/etc/gameserver.conf
LIB_DIR=/usr/local/lib/gameserver
BIN=/usr/local/bin
STATE_DIR=/var/lib/gameserver
HOOK_BEGIN='# >>> gameserver commands >>>'
HOOK_END='# <<< gameserver commands <<<'
STAMP=$(date +%Y%m%d-%H%M%S)

RECORD_DEPLOYED=0
ARGS=()
for A in "$@"
do
  case "$A" in
    --record-deployed) RECORD_DEPLOYED=1 ;;
    *) ARGS+=("$A") ;;
  esac
done
set -- "${ARGS[@]}"

# write_conf SPEL FIL: skriver spelets profil till FIL
write_conf() {
  case "$1" in
    @@GAME@@)
      cat > "$2" <<'CONFEOF'
@@PROFILE@@
CONFEOF
      ;;
    *)
      echo "Ingen profil för '$1' i den här filen (den är för @@GAME@@)."
      exit 1
      ;;
  esac
}

# Fråga 1: vilket spel (hoppas över om servern redan har en config)
if [ ! -f "$CONF" ]
then
  GAME="${1:-}"
  if [ -z "$GAME" ]
  then
    echo "Fråga 1: Vilket spel gäller den här servern?"
    echo "  1) @@GAME@@"
    read -r -p "Välj nummer eller namn: " ANS
    case "$ANS" in
      1|@@GAME@@) GAME=@@GAME@@ ;;
      *) GAME="$ANS" ;;
    esac
  fi
  write_conf "$GAME" "$CONF"
else
  # shellcheck disable=SC1090
  OLD_GAME=$(. "$CONF"; echo "$GAME")
  echo "Behåller befintlig $CONF (spel: $OLD_GAME)."
  # Lägg till nycklar som saknas i en äldre config; befintliga värden ändras aldrig
  NEW_CONF=$(mktemp)
  if (write_conf "$OLD_GAME" "$NEW_CONF") > /dev/null 2>&1
  then
    while IFS= read -r LINE
    do
      if ! grep -q "^${LINE%%=*}=" "$CONF"
      then
        echo "$LINE" >> "$CONF"
        echo "  lade till i $CONF: $LINE"
      fi
    done < "$NEW_CONF"
  fi
  rm -f "$NEW_CONF"
fi

# nano: password; python3: auto-update; git: update-lxc
PKGS=()
command -v nano > /dev/null 2>&1 || PKGS+=(nano)
command -v python3 > /dev/null 2>&1 || PKGS+=(python3)
command -v git > /dev/null 2>&1 || PKGS+=(git)
if [ "${#PKGS[@]}" -gt 0 ]
then
  if ! { apt-get update -qq && apt-get install -y "${PKGS[@]}"; }
  then
    echo "Varning: kunde inte installera ${PKGS[*]}. password behöver nano, auto-update python3, update-lxc git."
  fi
fi

mkdir -p "$LIB_DIR" "$STATE_DIR"

cat > "$LIB_DIR/common.sh" <<'GS_EOF_COMMON'
#@INLINE lib/common.sh
GS_EOF_COMMON

cat > "$LIB_DIR/gsquery.py" <<'GS_EOF_PY'
#@INLINE lib/gsquery.py
GS_EOF_PY
chmod +x "$LIB_DIR/gsquery.py"

cat > "$LIB_DIR/shell-init.sh" <<'GS_EOF_INIT'
#@INLINE lib/shell-init.sh
GS_EOF_INIT

# update-lxc skrivs till en ny fil som sedan byter plats, så att en körande update-lxc inte påverkas
cat > "$LIB_DIR/.update-lxc.sh.new" <<'GS_EOF_UPDATE'
#@INLINE lib/update-lxc.sh
GS_EOF_UPDATE
chmod +x "$LIB_DIR/.update-lxc.sh.new"
mv -f "$LIB_DIR/.update-lxc.sh.new" "$LIB_DIR/update-lxc.sh"

# systemd-timer för auto-update (slås på/av av kommandot auto-update)
cat > /etc/systemd/system/gameserver-autoupdate.service <<'UNITEOF'
[Unit]
Description=Game server auto-update check
After=network-online.target docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/auto-update run
UNITEOF

cat > /etc/systemd/system/gameserver-autoupdate.timer <<'UNITEOF'
[Unit]
Description=Game server auto-update check every minute

[Timer]
OnBootSec=2min
OnUnitActiveSec=1min
AccuracySec=10s

[Install]
WantedBy=timers.target
UNITEOF
systemctl daemon-reload > /dev/null 2>&1 || true

# Kommandona: tunna stubbar i /usr/local/bin som anropar biblioteket.
# Riktiga filer (inte alias/funktioner) så att de fungerar likadant i skript, cron, ssh och terminal.
mk() {
  printf '#!/bin/bash\n. %s/common.sh\n%s\n' "$LIB_DIR" "$2" > "$BIN/.$1.new"
  chmod 755 "$BIN/.$1.new"
  mv -f "$BIN/.$1.new" "$BIN/$1"
}

mk start gs_start
mk stop gs_stop
mk restart gs_restart
mk status gs_status
mk serverlog gs_serverlog
mk logs gs_logs
mk update-game gs_update
mk update 'echo "(update is now called update-game; update-lxc updates the server commands)" >&2
gs_update'
mk versions gs_versions
mk backup gs_backup
mk password 'gs_secrets "Did you save? Now run: restart"'
mk passwords 'gs_secrets "Did you save? Now run: restart"'
mk lösenord 'gs_secrets "Sparade du? Kör nu: restart"'
mk auto-update 'gs_autoupdate "$@"'
mk server-check 'gs_check "$@"'
mk server-help 'gs_help "$@"'
printf '#!/bin/bash\nexec bash %s/update-lxc.sh "$@"\n' "$LIB_DIR" > "$BIN/.update-lxc.new"
chmod 755 "$BIN/.update-lxc.new"
mv -f "$BIN/.update-lxc.new" "$BIN/update-lxc"

# Standard: auto-update på, uppdatera bara när servern har varit tom i 10 minuter.
# En befintlig inställning behålls.
if [ ! -f /etc/gameserver-autoupdate.conf ]
then
  cat > /etc/gameserver-autoupdate.conf <<'AUEOF'
# Auto-update settings. Change them with: auto-update
AUTO_UPDATE=on
UPDATE_WHEN_ONLINE=off
IDLE_MINUTES=10
CHECK_EVERY=30
AUEOF
fi
if grep -q '^AUTO_UPDATE=on' /etc/gameserver-autoupdate.conf
then
  systemctl enable --now gameserver-autoupdate.timer > /dev/null 2>&1 || true
else
  systemctl disable --now gameserver-autoupdate.timer > /dev/null 2>&1 || true
fi

# Var update-lxc hämtar uppdateringar (befintlig fil behålls)
if [ ! -f /etc/gameserver-repo.conf ]
then
  cat > /etc/gameserver-repo.conf <<'REPOEOF'
# Used by update-lxc. Only change these if you run your own fork.
REPO_URL=https://github.com/klangche/LXC-gameserver.git
REPO_BRANCH=main
REPO_DIR=/opt/lxc-gameserver
BACKUP_ROOT=/var/backups/gameserver
REPOEOF
fi

# ---------------------------------------------------------------- startfiler
# Ändrar bara exakt kända rader, sparar en kopia först och kontrollerar att filen
# fortfarande är giltig bash. Annat lämnas orört och visas av server-check.

# backup_once FIL: kopia före första ändringen
backup_once() {
  cp -p "$1" "$1.bak-gameserver-$STAMP"
  echo "  kopia: $1.bak-gameserver-$STAMP"
}

# replace_checked FIL NY: ersätter FIL med NY om NY är giltig bash, annars inget
replace_checked() {
  if bash -n "$2" 2>/dev/null
  then
    backup_once "$1"
    cat "$2" > "$1"
    rm -f "$2"
    return 0
  fi
  echo "  Varning: ändringen av $1 skulle ge ogiltig bash; filen lämnas orörd (kör server-check)."
  rm -f "$2"
  return 1
}

# 1) Det gamla blocket från tidigare versioner av detta skript (exakt text)
OLD_BLOCK='
# GAMESERVER_COMMANDS: visa serverkommandon vid varje interaktivt skal
if [ -n "$PS1" ] && command -v server-help > /dev/null 2>&1
then
  server-help
  alias help="server-help"
fi
'
if grep -q 'GAMESERVER_COMMANDS' /etc/bash.bashrc 2>/dev/null
then
  TMP=$(mktemp)
  if OLD_BLOCK="$OLD_BLOCK" python3 - /etc/bash.bashrc "$TMP" <<'PYFIX'
import os, sys
src = open(sys.argv[1]).read()
old = os.environ["OLD_BLOCK"]
if old not in src:
    sys.exit(1)
open(sys.argv[2], "w").write(src.replace(old, "\n", 1))
PYFIX
  then
    echo "Tar bort det gamla GAMESERVER_COMMANDS-blocket (och alias help) ur /etc/bash.bashrc"
    replace_checked /etc/bash.bashrc "$TMP" || true
  else
    rm -f "$TMP"
    echo "  Varning: /etc/bash.bashrc har ett ändrat GAMESERVER_COMMANDS-block; lämnas orört (kör server-check)."
  fi
fi

# 2) Den första manuella listan (CUSTOM_CMDS) i /etc/bash.bashrc: blocket fram till första "fi"
if grep -q '# CUSTOM_CMDS' /etc/bash.bashrc 2>/dev/null
then
  TMP=$(mktemp)
  START=$(grep -n '# CUSTOM_CMDS' /etc/bash.bashrc | head -n1 | cut -d: -f1)
  END=$(awk -v s="$START" 'NR > s && /^fi$/ {print NR; exit}' /etc/bash.bashrc)
  if [ -n "$END" ] && [ $((END - START)) -le 40 ]
  then
    echo "Tar bort det gamla CUSTOM_CMDS-blocket (rad $START-$END) ur /etc/bash.bashrc:"
    sed -n "${START},${END}p" /etc/bash.bashrc | sed 's/^/    /'
    sed "${START},${END}d" /etc/bash.bashrc > "$TMP"
    replace_checked /etc/bash.bashrc "$TMP" || true
  else
    rm -f "$TMP"
    echo "  Varning: CUSTOM_CMDS-blocket i /etc/bash.bashrc har inget tydligt slut; lämnas orört (kör server-check)."
  fi
fi

# 3) Den gamla spelspecifika hjälpen
rm -f "$BIN/enshrouded-help"
if [ -f /root/.bashrc ] && grep -q 'enshrouded-help' /root/.bashrc
then
  TMP=$(mktemp)
  echo "Tar bort enshrouded-help ur /root/.bashrc:"
  grep -n 'enshrouded-help' /root/.bashrc | sed 's/^/    rad /'
  # Raden byts mot ":" (gör ingenting) i stället för att tas bort, så att ett omgivande if/fi förblir giltigt
  sed -E 's/^([[:space:]]*)enshrouded-help[[:space:]]*$/\1: # enshrouded-help removed by install-server-commands.sh/' /root/.bashrc > "$TMP"
  replace_checked /root/.bashrc "$TMP" || true
fi

# 4) Det nya blocket i /etc/bash.bashrc (mellan markörerna, byts ut vid ominstallation)
HOOK="$HOOK_BEGIN
# Shows the server commands in interactive shells. Managed by install-server-commands.sh.
[ -r $LIB_DIR/shell-init.sh ] && . $LIB_DIR/shell-init.sh
$HOOK_END"
if grep -qF "$HOOK_BEGIN" /etc/bash.bashrc 2>/dev/null
then
  if grep -qF "$HOOK_END" /etc/bash.bashrc
  then
    TMP=$(mktemp)
    HOOK="$HOOK" awk -v b="$HOOK_BEGIN" -v e="$HOOK_END" '
      $0 == b {print ENVIRON["HOOK"]; skip = 1; next}
      $0 == e {skip = 0; next}
      !skip {print}' /etc/bash.bashrc > "$TMP"
    if cmp -s "$TMP" /etc/bash.bashrc
    then
      rm -f "$TMP"
    else
      replace_checked /etc/bash.bashrc "$TMP" || true
    fi
  else
    echo "  Varning: /etc/bash.bashrc har '$HOOK_BEGIN' utan slutmarkör; lämnas orört (kör server-check)."
  fi
else
  printf '\n%s\n' "$HOOK" >> /etc/bash.bashrc
fi

# 5) Inloggningsskal som inte läser /etc/bash.bashrc (spärren i shell-init.sh hindrar dubbel lista)
cat > /etc/profile.d/zz-gameserver.sh <<INITEOF
# Shows the server commands in interactive login shells. Managed by install-server-commands.sh.
[ -n "\${BASH_VERSION:-}" ] && [ -r $LIB_DIR/shell-init.sh ] && . $LIB_DIR/shell-init.sh
INITEOF

# Kontrollsummor för de genererade filerna (update-lxc ser då om någon ändrats för hand)
sha256sum "$LIB_DIR/common.sh" "$LIB_DIR/gsquery.py" "$LIB_DIR/shell-init.sh" "$LIB_DIR/update-lxc.sh" \
  /etc/systemd/system/gameserver-autoupdate.service /etc/systemd/system/gameserver-autoupdate.timer \
  /etc/profile.d/zz-gameserver.sh > "$STATE_DIR/generated.sha256"

# Vid en ny installation (install.sh): filerna i spelmappen kommer orörda från repot
if [ "$RECORD_DEPLOYED" = 1 ]
then
  # shellcheck disable=SC1090
  GDIR=$(. "$CONF"; echo "$DIR")
  sha256sum "$GDIR/docker-compose.yml" "$GDIR/install-server-commands.sh" > "$STATE_DIR/deployed.sha256"
fi

echo
echo "Klart. Öppna ett nytt skal (skriv: bash) eller kör: server-help. Kontroll: server-check"

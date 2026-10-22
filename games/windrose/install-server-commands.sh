#!/bin/bash
# install-server-commands.sh
#
# Installerar samma serverkommandon på varje spel-LXC, oavsett om spelet körs
# i Docker (MODE=docker) eller native med systemd + steamcmd (MODE=native):
#   start, stop, restart, status, serverlog, logs, update, versions, backup,
#   password (alias: passwords, lösenord), server-help (alias: help)
#
# Sätter INTE upp någon spelserver. Kan köras om för att uppdatera kommandona.
# Det enda som skiljer mellan servrarna är /etc/gameserver.conf.
# Skriv "bash" i en terminal för att få upp listan igen.

set -e

if [ "$(id -u)" -ne 0 ]
then
  echo "Kör som root."
  exit 1
fi

CONF=/etc/gameserver.conf
LIB_DIR=/usr/local/lib/gameserver
BIN=/usr/local/bin

write_conf() {
  case "$1" in
    windrose)
      cat > "$CONF" <<'CONFEOF'
GAME=windrose
MODE=docker
DIR=/opt/windrose
CONTAINER=windrose
GAME_LOG=
DATA_DIR=data
SAVE_SUB=.
SECRETS_FILE=passwords.env
APP_ID=
INSTALL_DIR=/data
CONFEOF
      ;;
    *)
      echo "Ingen profil för '$1' än. Lägg till ett case i write_conf först."
      echo "Native-spel använder MODE=native med dessa variabler:"
      echo "  GAME MODE DIR SERVICE RUN_USER INSTALL_DIR APP_ID STEAMCMD SAVE_PATH"
      echo "  SECRETS_PATH (valfri) GAME_LOG (valfri) FORCE_PLATFORM (valfri) PROTON_DIR (valfri)"
      exit 1
      ;;
  esac
}

# Fråga 1: alltid vilket spel (hoppas över om servern redan har en config)
if [ ! -f "$CONF" ]
then
  GAME="${1:-}"
  if [ -z "$GAME" ]
  then
    echo "Fråga 1: Vilket spel gäller den här servern?"
    echo "  1) windrose"
    read -r -p "Välj nummer eller namn: " ANS
    case "$ANS" in
      1|windrose) GAME=windrose ;;
      *) GAME="$ANS" ;;
    esac
  fi
  write_conf "$GAME"
else
  echo "Behåller befintlig $CONF (spel: $(. "$CONF"; echo "$GAME"))."
fi

# nano behövs av password och lösenord
if ! command -v nano > /dev/null 2>&1
then
  if ! { apt-get update -qq && apt-get install -y nano; }
  then
    echo "Varning: kunde inte installera nano. password och lösenord fungerar inte förrän nano finns."
  fi
fi

mkdir -p "$LIB_DIR"

cat > "$LIB_DIR/common.sh" <<'LIBEOF'
#!/bin/bash
# Gemensamt bibliotek för alla serverkommandon. Läser /etc/gameserver.conf.
# MODE=docker: spelet körs i en container via docker compose.
# MODE=native: spelet körs som en systemd-tjänst, uppdateras med steamcmd.
# GAME_LOG tomt = använd docker logs. APP_ID tomt = imagen uppdaterar spelet själv.

CONF=/etc/gameserver.conf
if [ ! -f "$CONF" ]
then
  echo "Saknar $CONF. Kör install-server-commands.sh först."
  exit 1
fi
. "$CONF"
SECRETS_PATH="${SECRETS_PATH:-$DIR/$SECRETS_FILE}"

# Anropar gs_<MODE>_<kommando>
gs_dispatch() {
  local fn="gs_${MODE}_$1"
  shift
  if declare -F "$fn" > /dev/null
  then
    "$fn" "$@"
  else
    echo "MODE=$MODE stöds inte för det här kommandot."
    exit 1
  fi
}

gs_start()     { gs_dispatch start; }
gs_stop()      { gs_dispatch stop; }
gs_restart()   { gs_dispatch restart; }
gs_status()    { gs_dispatch status; }
gs_serverlog() { gs_dispatch serverlog; }
gs_logs()      { gs_dispatch logs; }
gs_backup()    { gs_dispatch backup; }
gs_versions()  { gs_dispatch versions; }
gs_update()    { gs_dispatch update; }

gs_secrets() {
  nano "$SECRETS_PATH"
  echo
  echo "$1"
}

# Plockar ut det senaste public-bygget ur steamcmds app_info_print
gs_parse_latest() {
  awk '/"branches"/{b=1} b&&/"public"/{p=1} p&&/"buildid"/{gsub(/"/,"",$2); print $2; exit}'
}

# ---------------------------------------------------------------- docker

gs_docker_start() {
  cd "$DIR" && docker compose up -d && echo "Server starting..."
}

gs_docker_stop() {
  cd "$DIR" && docker compose down && echo "Server stopped."
}

gs_docker_restart() {
  cd "$DIR" || exit 1
  docker compose down
  docker compose up -d
  echo "Server restarting..."
}

gs_docker_status() {
  echo "=== Container status ==="
  cd "$DIR" && docker compose ps
  echo
  if [ -n "$GAME_LOG" ]
  then
    echo "=== Last lines from $(basename "$GAME_LOG") ==="
    docker exec "$CONTAINER" tail -n 15 "$GAME_LOG" 2>/dev/null || echo "Log not ready yet"
  else
    echo "=== Last lines from the container log ==="
    docker compose logs --tail 15 2>/dev/null || echo "Log not ready yet"
  fi
  echo
}

gs_docker_serverlog() {
  if [ -n "$GAME_LOG" ]
  then
    docker exec -it "$CONTAINER" tail -f "$GAME_LOG"
  else
    cd "$DIR" && docker compose logs -f --tail 50
  fi
}

gs_docker_logs() {
  cd "$DIR" && docker compose logs -f --tail 100
}

gs_docker_backup() {
  cd "$DIR" || exit 1
  mkdir -p backups
  local STAMP OUT
  STAMP=$(date +%Y%m%d-%H%M%S)
  OUT="backups/savegame-$STAMP.tar.gz"
  if tar -czf "$OUT" -C "$DATA_DIR" "$SAVE_SUB" 2>/dev/null || tar -czf "$OUT" "$DATA_DIR"
  then
    echo "Backup saved: $DIR/$OUT"
  else
    echo "Backup failed"
    return 1
  fi
}

gs_docker_find_steamcmd() {
  SC=$(docker exec "$CONTAINER" sh -c 'command -v steamcmd || ls /home/steam/steamcmd/steamcmd.sh 2>/dev/null' 2>/dev/null | head -n1)
}

gs_docker_run_steam() {
  local PLAT=()
  if [ -n "$FORCE_PLATFORM" ]
  then
    PLAT=(+@sSteamCmdForcePlatformType "$FORCE_PLATFORM")
  fi
  docker exec -u steam "$CONTAINER" "$SC" "${PLAT[@]}" +force_install_dir "$INSTALL_DIR" +login anonymous +app_update "$APP_ID" "$@" +quit
}

gs_docker_versions() {
  local M="$INSTALL_DIR/steamapps/appmanifest_${APP_ID}.acf"
  local IMG INST UPD LATEST
  IMG=$(docker inspect --format='{{.Config.Image}}' "$CONTAINER" 2>/dev/null)
  echo "=== Versions ==="
  echo "Docker image: $IMG"
  echo -n "Image created: "
  docker image inspect "$IMG" --format='{{.Created}}' 2>/dev/null | cut -d'T' -f1
  if [ -z "$APP_ID" ]
  then
    echo
    echo "The image updates the game itself; run 'update' to pull a newer image."
    return 0
  fi
  echo
  echo "Game (app $APP_ID):"
  INST=$(docker exec "$CONTAINER" sh -c "grep -m1 '\"buildid\"' $M" 2>/dev/null | grep -oE '[0-9]+')
  UPD=$(docker exec "$CONTAINER" sh -c "grep -m1 '\"LastUpdated\"' $M" 2>/dev/null | grep -oE '[0-9]+')
  echo "  Installed build: ${INST:-unknown}"
  if [ -n "$UPD" ]
  then
    echo "  Installed updated: $(date -d @"$UPD" '+%Y-%m-%d %H:%M')"
  fi
  gs_docker_find_steamcmd
  if [ -n "$SC" ]
  then
    LATEST=$(docker exec "$CONTAINER" "$SC" +login anonymous +app_info_update 1 +app_info_print "$APP_ID" +quit 2>/dev/null | gs_parse_latest)
    gs_print_compare "$INST" "$LATEST"
  else
    echo "  Latest build:    steamcmd not found in container"
  fi
  if [ -n "$PROTON_DIR" ]
  then
    echo
    echo "Proton version:"
    docker exec "$CONTAINER" sh -c "cat '$PROTON_DIR/version' 2>/dev/null || ls '$PROTON_DIR' | head -n 5"
  fi
}

gs_print_compare() {
  echo "  Latest build:    ${2:-unknown}"
  if [ -n "$1" ] && [ -n "$2" ]
  then
    if [ "$1" = "$2" ]
    then
      echo "  Status: up to date"
    else
      echo "  Status: UPDATE AVAILABLE"
    fi
  fi
}

gs_docker_update() {
  cd "$DIR" || exit 1
  local M="$INSTALL_DIR/steamapps/appmanifest_${APP_ID}.acf"
  echo "Backing up savegame..."
  gs_docker_backup || { echo "Backup failed, aborting update."; exit 1; }
  echo "Updating image..."
  docker compose pull
  docker compose up -d
  if [ -z "$APP_ID" ]
  then
    echo "Restarting server (the image updates the game files on start)..."
    docker compose restart
    echo "Done."
    gs_docker_versions
    return 0
  fi
  gs_docker_find_steamcmd
  if [ -z "$SC" ]
  then
    echo "steamcmd not found in container"
    exit 1
  fi
  echo "Updating game files..."
  if ! gs_docker_run_steam
  then
    echo "Update failed, moving appmanifest aside and validating..."
    docker exec -u steam "$CONTAINER" mv -f "$M" "$M.old"
    gs_docker_run_steam validate || { echo "Update failed again"; exit 1; }
  fi
  echo "Restarting server..."
  docker compose restart
  echo "Done."
  gs_docker_versions
}

# ---------------------------------------------------------------- native

gs_native_taillog() {
  if [ -n "$GAME_LOG" ] && [ -f "$GAME_LOG" ]
  then
    tail -n "$1" "$GAME_LOG"
  else
    journalctl -u "$SERVICE" -n "$1" --no-pager
  fi
}

gs_native_start() {
  systemctl start "$SERVICE" && echo "Server starting..."
}

gs_native_stop() {
  systemctl stop "$SERVICE" && echo "Server stopped."
}

gs_native_restart() {
  systemctl restart "$SERVICE" && echo "Server restarting..."
}

gs_native_status() {
  echo "=== Service status ==="
  systemctl status "$SERVICE" --no-pager -n 0 2>&1 | head -n 12
  echo
  echo "=== Last log lines ==="
  gs_native_taillog 15
  echo
}

gs_native_serverlog() {
  if [ -n "$GAME_LOG" ] && [ -f "$GAME_LOG" ]
  then
    tail -f "$GAME_LOG"
  else
    journalctl -u "$SERVICE" -n 50 -f
  fi
}

gs_native_logs() {
  journalctl -u "$SERVICE" -n 100 -f
}

gs_native_backup() {
  mkdir -p "$DIR/backups"
  local STAMP OUT
  STAMP=$(date +%Y%m%d-%H%M%S)
  OUT="$DIR/backups/savegame-$STAMP.tar.gz"
  if tar -czf "$OUT" -C "$(dirname "$SAVE_PATH")" "$(basename "$SAVE_PATH")"
  then
    echo "Backup saved: $OUT"
  else
    echo "Backup failed"
    return 1
  fi
}

gs_native_run_steam() {
  local PLAT=()
  if [ -n "$FORCE_PLATFORM" ]
  then
    PLAT=(+@sSteamCmdForcePlatformType "$FORCE_PLATFORM")
  fi
  runuser -u "$RUN_USER" -- "$STEAMCMD" "${PLAT[@]}" +force_install_dir "$INSTALL_DIR" +login anonymous +app_update "$APP_ID" "$@" +quit
}

gs_native_versions() {
  local M="$INSTALL_DIR/steamapps/appmanifest_${APP_ID}.acf"
  local INST UPD LATEST
  echo "=== Versions ==="
  echo "Service: $SERVICE ($(systemctl is-active "$SERVICE" 2>/dev/null))"
  echo
  echo "Game (app $APP_ID):"
  INST=$(grep -m1 '"buildid"' "$M" 2>/dev/null | grep -oE '[0-9]+')
  UPD=$(grep -m1 '"LastUpdated"' "$M" 2>/dev/null | grep -oE '[0-9]+')
  echo "  Installed build: ${INST:-unknown}"
  if [ -n "$UPD" ]
  then
    echo "  Installed updated: $(date -d @"$UPD" '+%Y-%m-%d %H:%M')"
  fi
  if command -v "$STEAMCMD" > /dev/null 2>&1
  then
    LATEST=$(runuser -u "$RUN_USER" -- "$STEAMCMD" +login anonymous +app_info_update 1 +app_info_print "$APP_ID" +quit 2>/dev/null | gs_parse_latest)
    gs_print_compare "$INST" "$LATEST"
  else
    echo "  Latest build:    steamcmd not found ($STEAMCMD)"
  fi
  if [ -n "$PROTON_DIR" ]
  then
    echo
    echo "Proton version:"
    cat "$PROTON_DIR/version" 2>/dev/null || ls "$PROTON_DIR" 2>/dev/null | head -n 5
  fi
}

gs_native_update() {
  local M="$INSTALL_DIR/steamapps/appmanifest_${APP_ID}.acf"
  local WAS
  echo "Backing up savegame..."
  gs_native_backup || { echo "Backup failed, aborting update."; exit 1; }
  WAS=$(systemctl is-active "$SERVICE" 2>/dev/null)
  echo "Stopping server..."
  systemctl stop "$SERVICE"
  echo "Updating game files..."
  if ! gs_native_run_steam
  then
    echo "Update failed, moving appmanifest aside and validating..."
    mv -f "$M" "$M.old"
    if ! gs_native_run_steam validate
    then
      echo "Update failed again"
      if [ "$WAS" = "active" ]
      then
        echo "Starting the server on the old files..."
        systemctl start "$SERVICE"
      fi
      exit 1
    fi
  fi
  if [ "$WAS" = "active" ]
  then
    echo "Starting server..."
    systemctl start "$SERVICE"
  fi
  echo "Done."
  gs_native_versions
}

# ---------------------------------------------------------------- hjälp

gs_help() {
  echo
  echo "=== ${GAME^} commands ($MODE) ==="
  echo "  status      - server status + last lines from the server log"
  echo "  serverlog   - live tail of the server log (most important)"
  echo "  start       - start the server"
  echo "  stop        - stop the server"
  echo "  restart     - restart the server"
  echo "  update      - backup, update game files, restart"
  echo "  password    - edit ALL passwords in nano (also: passwords, lösenord)"
  echo "  logs        - live system/container logs"
  echo "  versions    - show installed vs latest game version"
  echo "  backup      - quick backup of savegame"
  echo "  help        - show this list (or just type: bash)"
  echo
}
LIBEOF

# Kommandona: tunna stubbar som anropar biblioteket, identiska på alla servrar
mk() {
  printf '#!/bin/bash\n. %s/common.sh\n%s\n' "$LIB_DIR" "$2" > "$BIN/$1"
  chmod +x "$BIN/$1"
}

mk start gs_start
mk stop gs_stop
mk restart gs_restart
mk status gs_status
mk serverlog gs_serverlog
mk logs gs_logs
mk update gs_update
mk versions gs_versions
mk backup gs_backup
mk password 'gs_secrets "Did you save? Now run: restart"'
mk passwords 'gs_secrets "Did you save? Now run: restart"'
mk lösenord 'gs_secrets "Sparade du? Kör nu: restart"'
mk server-help gs_help

# Städa bort den gamla spelspecifika hjälpen och dess anrop
rm -f "$BIN/enshrouded-help"
if [ -f /root/.bashrc ] && grep -q 'enshrouded-help' /root/.bashrc
then
  [ -e /root/.bashrc.bak-servercmds ] || cp /root/.bashrc /root/.bashrc.bak-servercmds
  sed -i '/enshrouded-help/d' /root/.bashrc
fi

# Ta bort den tidigare listan (CUSTOM_CMDS) så att inget visas dubbelt
if grep -q 'CUSTOM_CMDS' /etc/bash.bashrc
then
  [ -e /etc/bash.bashrc.bak-servercmds ] || cp /etc/bash.bashrc /etc/bash.bashrc.bak-servercmds
  sed -i '/# CUSTOM_CMDS/,/^fi$/d' /etc/bash.bashrc
fi

# Visa kommandolistan vid varje interaktivt skal (inloggning, SSH, pct enter, bash)
if ! grep -q 'GAMESERVER_COMMANDS' /etc/bash.bashrc
then
  cat >> /etc/bash.bashrc <<'RCEOF'

# GAMESERVER_COMMANDS: visa serverkommandon vid varje interaktivt skal
if [ -n "$PS1" ] && command -v server-help > /dev/null 2>&1
then
  server-help
  alias help="server-help"
fi
RCEOF
fi

echo
echo "Klart. Öppna ett nytt skal (skriv: bash) eller kör: server-help"

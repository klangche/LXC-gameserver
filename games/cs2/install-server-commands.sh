#!/bin/bash
# install-server-commands.sh
#
# Installerar samma serverkommandon på varje spel-LXC, oavsett om spelet körs
# i Docker (MODE=docker) eller native med systemd + steamcmd (MODE=native):
#   start, stop, restart, status, serverlog, logs, update, versions, backup,
#   password (alias: passwords, lösenord), auto-update, server-help (alias: help)
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

# write_conf SPEL FIL: skriver spelets profil till FIL
write_conf() {
  case "$1" in
    cs2)
      cat > "$2" <<'CONFEOF'
GAME=cs2
MODE=docker
DIR=/opt/cs2
CONTAINER=cs2
GAME_LOG=
DATA_DIR=data
SAVE_SUB=.
SECRETS_FILE=passwords.env
APP_ID=
INSTALL_DIR=/home/steam/cs2-dedicated
PLAYER_QUERY=a2s:27015
CHECK_APP_ID=730
VERSION_CHECK=
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
    echo "  1) cs2"
    read -r -p "Välj nummer eller namn: " ANS
    case "$ANS" in
      1|cs2) GAME=cs2 ;;
      *) GAME="$ANS" ;;
    esac
  fi
  write_conf "$GAME" "$CONF"
else
  OLD_GAME=$(. "$CONF"; echo "$GAME")
  echo "Behåller befintlig $CONF (spel: $OLD_GAME)."
  # Lägg till nycklar som saknas i en äldre config (t.ex. de som auto-update behöver)
  NEW_CONF=$(mktemp)
  if (write_conf "$OLD_GAME" "$NEW_CONF") > /dev/null 2>&1
  then
    while IFS= read -r LINE
    do
      grep -q "^${LINE%%=*}=" "$CONF" || echo "$LINE" >> "$CONF"
    done < "$NEW_CONF"
  fi
  rm -f "$NEW_CONF"
fi

# nano behövs av password och lösenord, python3 av auto-update
PKGS=()
command -v nano > /dev/null 2>&1 || PKGS+=(nano)
command -v python3 > /dev/null 2>&1 || PKGS+=(python3)
if [ "${#PKGS[@]}" -gt 0 ]
then
  if ! { apt-get update -qq && apt-get install -y "${PKGS[@]}"; }
  then
    echo "Varning: kunde inte installera ${PKGS[*]}. password/lösenord behöver nano, auto-update behöver python3."
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

# ---------------------------------------------------------------- auto-update
# Inställningar i /etc/gameserver-autoupdate.conf, tillstånd i /var/lib/gameserver.
# En systemd-timer kör "auto-update run" varje minut när auto-update är på (bara om servern körs):
#   - var CHECK_EVERY:e minut letas efter en ny image / nytt Steam-bygge / ny Minecraft-version
#   - finns en uppdatering körs "update" direkt (om UPDATE_WHEN_ONLINE=on), annars när
#     servern har varit tom i IDLE_MINUTES minuter.
# Spelspecifikt i /etc/gameserver.conf: PLAYER_QUERY (a2s:PORT[,PORT] | minecraft | tomt),
# CHECK_APP_ID (Steam-app för att se nya byggen, tomt = bara image) och VERSION_CHECK (minecraft).

AU_CONF=/etc/gameserver-autoupdate.conf
AU_STATE_DIR=/var/lib/gameserver
AU_STATE="$AU_STATE_DIR/auto-update.state"
AU_LOG=/var/log/gameserver-autoupdate.log
AU_QUERY=/usr/local/lib/gameserver/gsquery.py

gs_au_load() {
  AUTO_UPDATE=off
  UPDATE_WHEN_ONLINE=off
  IDLE_MINUTES=10
  CHECK_EVERY=30
  if [ -f "$AU_CONF" ]
  then
    . "$AU_CONF"
  fi
  IDLE_SINCE=
  LAST_CHECK=0
  PENDING=
  LAST_TRY=
  if [ -f "$AU_STATE" ]
  then
    . "$AU_STATE"
  fi
}

gs_au_save_conf() {
  cat > "$AU_CONF" <<AUEOF
# Auto-update settings. Change them with: auto-update
AUTO_UPDATE=$AUTO_UPDATE
UPDATE_WHEN_ONLINE=$UPDATE_WHEN_ONLINE
IDLE_MINUTES=$IDLE_MINUTES
CHECK_EVERY=$CHECK_EVERY
AUEOF
}

gs_au_save_state() {
  mkdir -p "$AU_STATE_DIR"
  cat > "$AU_STATE" <<AUEOF
IDLE_SINCE=$IDLE_SINCE
LAST_CHECK=$LAST_CHECK
PENDING='$PENDING'
LAST_TRY='$LAST_TRY'
AUEOF
}

gs_au_log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$AU_LOG"
}

# Adress som spelets query-port nås på från LXC:n
gs_au_host() {
  local IP=
  if [ "$MODE" = docker ]
  then
    IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$CONTAINER" 2>/dev/null)
  fi
  echo "${IP:-127.0.0.1}"
}

# Skriver ut antal spelare online, eller inget om det inte går att avgöra
gs_au_players() {
  case "$PLAYER_QUERY" in
    a2s:*)
      python3 "$AU_QUERY" a2s "$(gs_au_host)" "${PLAYER_QUERY#a2s:}" 2>/dev/null
      ;;
    minecraft)
      docker exec "$CONTAINER" rcon-cli list 2>/dev/null | grep -oE 'There are [0-9]+' | grep -oE '[0-9]+'
      ;;
  esac
}

gs_au_running() {
  if [ "$MODE" = docker ]
  then
    [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null)" = true ]
  else
    systemctl is-active --quiet "$SERVICE"
  fi
}

# Installerat Steam-bygge (från appmanifest i spelets mappar)
gs_au_installed_build() {
  local M
  M=$(find "$DIR" "$INSTALL_DIR" -maxdepth 6 -name "appmanifest_${CHECK_APP_ID}.acf" 2>/dev/null | head -n1)
  if [ -n "$M" ]
  then
    grep -m1 '"buildid"' "$M" | grep -oE '[0-9]+'
  elif [ "$MODE" = docker ]
  then
    docker exec "$CONTAINER" sh -c "grep -m1 '\"buildid\"' $INSTALL_DIR/steamapps/appmanifest_${CHECK_APP_ID}.acf" 2>/dev/null | grep -oE '[0-9]+'
  fi
}

# Sätter PENDING till en beskrivning av uppdateringen som finns, annars tomt
gs_au_check() {
  local IMG OLD NEW INST LATEST
  PENDING=
  if [ "$MODE" = docker ]
  then
    IMG=$(docker inspect -f '{{.Config.Image}}' "$CONTAINER" 2>/dev/null)
    OLD=$(docker inspect -f '{{.Image}}' "$CONTAINER" 2>/dev/null)
    if [ -n "$IMG" ] && (cd "$DIR" && docker compose pull -q) > /dev/null 2>&1
    then
      NEW=$(docker image inspect -f '{{.Id}}' "$IMG" 2>/dev/null)
      if [ -n "$NEW" ] && [ -n "$OLD" ] && [ "$NEW" != "$OLD" ]
      then
        PENDING="image:${NEW:7:12}"
        return 0
      fi
    fi
  fi
  if [ -n "$CHECK_APP_ID" ]
  then
    INST=$(gs_au_installed_build)
    LATEST=$(python3 "$AU_QUERY" steam-latest "$CHECK_APP_ID" 2>/dev/null)
    if [ -n "$INST" ] && [ -n "$LATEST" ] && [ "$INST" != "$LATEST" ]
    then
      PENDING="build:$LATEST"
      return 0
    fi
  fi
  if [ "$VERSION_CHECK" = minecraft ]
  then
    INST=$(docker exec "$CONTAINER" mc-monitor status 2>/dev/null | grep -oE 'version=[^ ]+' | cut -d= -f2)
    LATEST=$(python3 "$AU_QUERY" mc-latest 2>/dev/null)
    if [ -n "$INST" ] && [ -n "$LATEST" ] && [ "$INST" != "$LATEST" ]
    then
      PENDING="minecraft:$LATEST"
    fi
  fi
}

# Körs av systemd-timern varje minut
gs_au_run() {
  local NOW P
  exec 9> /run/gameserver-autoupdate.lock
  flock -n 9 || return 0
  gs_au_load
  [ "$AUTO_UPDATE" = on ] || return 0
  NOW=$(date +%s)

  # En stoppad server lämnas i fred (update skulle starta den)
  if ! gs_au_running
  then
    IDLE_SINCE=
    gs_au_save_state
    return 0
  fi

  # Håll koll på hur länge servern har varit tom
  P=$(gs_au_players)
  if [ "$P" = 0 ]
  then
    IDLE_SINCE=${IDLE_SINCE:-$NOW}
  else
    IDLE_SINCE=
  fi

  if [ $((NOW - LAST_CHECK)) -ge $((CHECK_EVERY * 60)) ]
  then
    LAST_CHECK=$NOW
    gs_au_check
    if [ -n "$PENDING" ] && [ "$PENDING" = "$LAST_TRY" ]
    then
      # Samma uppdatering har redan körts utan att gå igenom; försök inte om och om igen
      PENDING=
    elif [ -n "$PENDING" ]
    then
      gs_au_log "Update available ($PENDING)"
      if [ "$UPDATE_WHEN_ONLINE" != on ] && [ -z "$P" ]
      then
        gs_au_log "Update waiting: cannot read the player count (PLAYER_QUERY='$PLAYER_QUERY')"
      fi
    fi
  fi

  if [ -n "$PENDING" ]
  then
    if [ "$UPDATE_WHEN_ONLINE" = on ]
    then
      gs_au_log "Updating now ($PENDING, players online: ${P:-unknown})"
    elif [ -n "$IDLE_SINCE" ] && [ $((NOW - IDLE_SINCE)) -ge $((IDLE_MINUTES * 60)) ]
    then
      gs_au_log "Updating ($PENDING): no players for $(( (NOW - IDLE_SINCE) / 60 )) min"
    else
      gs_au_save_state
      return 0
    fi
    LAST_TRY=$PENDING
    PENDING=
    gs_au_save_state
    if (gs_update) >> "$AU_LOG" 2>&1
    then
      gs_au_log "Update finished"
    else
      gs_au_log "Update FAILED, see the lines above"
    fi
    IDLE_SINCE=
  fi
  gs_au_save_state
}

gs_au_timer() {
  if [ "$AUTO_UPDATE" = on ]
  then
    systemctl enable --now gameserver-autoupdate.timer > /dev/null 2>&1
  else
    systemctl disable --now gameserver-autoupdate.timer > /dev/null 2>&1
  fi
}

gs_au_status() {
  gs_au_load
  echo "=== Auto-update ==="
  echo "  Auto-update:                  $AUTO_UPDATE"
  echo "  Update while players online:  $UPDATE_WHEN_ONLINE"
  if [ "$UPDATE_WHEN_ONLINE" != on ]
  then
    echo "  Update after empty for:       $IDLE_MINUTES min"
  fi
  echo "  Checks for updates every:     $CHECK_EVERY min"
  if [ -n "$PENDING" ]
  then
    echo "  Waiting update:               $PENDING"
  fi
  echo "  Log:                          $AU_LOG"
}

# Svarar ja/nej, standard nej
gs_au_yes() {
  local A
  read -r -p "$1 [y/N]: " A
  case "$A" in y | Y | yes | YES | j | J | ja | JA) return 0 ;; *) return 1 ;; esac
}

gs_au_toggle() {
  if [ "${!1}" = on ]
  then
    printf -v "$1" off
  else
    printf -v "$1" on
  fi
}

gs_autoupdate() {
  local A
  case "${1:-}" in
    run) gs_au_run; return ;;
    status) gs_au_status; return ;;
    log) tail -n 50 "$AU_LOG" 2>/dev/null || echo "No auto-update log yet."; return ;;
    on | off)
      gs_au_load
      AUTO_UPDATE=$1
      gs_au_save_conf
      gs_au_timer
      gs_au_status
      return
      ;;
    "") ;;
    *) echo "Usage: auto-update [on|off|status|log]"; return 1 ;;
  esac

  gs_au_status
  echo

  # Fråga 1: auto-update på/av
  if [ "$AUTO_UPDATE" = on ]
  then
    gs_au_yes "1) Auto-update is ON. Switch it OFF?" && gs_au_toggle AUTO_UPDATE
  else
    gs_au_yes "1) Auto-update is OFF. Switch it ON?" && gs_au_toggle AUTO_UPDATE
  fi

  # Fråga 2: uppdatera även när spelare är online
  if [ "$UPDATE_WHEN_ONLINE" = on ]
  then
    gs_au_yes "2) Update even if players are online is ON. Switch it OFF (wait until the server is empty)?" && gs_au_toggle UPDATE_WHEN_ONLINE
  else
    gs_au_yes "2) Update even if players are online is OFF. Switch it ON?" && gs_au_toggle UPDATE_WHEN_ONLINE
  fi

  # Fråga 3: bara när vi väntar på att servern ska bli tom
  if [ "$UPDATE_WHEN_ONLINE" != on ]
  then
    while true
    do
      read -r -p "3) Update after how many minutes with no players online? [$IDLE_MINUTES]: " A
      A=${A:-$IDLE_MINUTES}
      if [[ "$A" =~ ^[0-9]+$ ]]
      then
        IDLE_MINUTES=$((10#$A))
        break
      fi
      echo "  Enter a number of minutes (0 = as soon as the server is empty)."
    done
  fi

  gs_au_save_conf
  gs_au_timer
  echo
  gs_au_status
  if [ "$AUTO_UPDATE" = on ] && [ "$UPDATE_WHEN_ONLINE" != on ] && [ -z "$PLAYER_QUERY" ]
  then
    echo
    echo "Note: this game has no player check (PLAYER_QUERY is empty in $CONF),"
    echo "so updates only run if 'Update even if players are online' is ON."
  fi
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
  echo "  auto-update - turn automatic updates on/off (also: auto-update status|log)"
  echo "  help        - show this list (or just type: bash)"
  echo
}
LIBEOF

cat > "$LIB_DIR/gsquery.py" <<'PYEOF'
#!/usr/bin/env python3
# Hjälpverktyg för auto-update. Skriver ut ett värde eller avslutar med kod 1.
#   gsquery.py a2s HOST PORT[,PORT...]   antal spelare via Steam A2S_INFO
#   gsquery.py steam-latest APPID        senaste public-build (api.steamcmd.net)
#   gsquery.py mc-latest                 senaste Minecraft release (Mojang)
import json
import socket
import sys
import urllib.request


def a2s_players(host, port, timeout=3.0):
    req = b"\xff\xff\xff\xffTSource Engine Query\x00"
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(timeout)
    try:
        s.sendto(req, (host, port))
        data, _ = s.recvfrom(4096)
        # Servern kan svara med en challenge som ska skickas tillbaka
        if len(data) >= 9 and data[4] == 0x41:
            s.sendto(req + data[5:9], (host, port))
            data, _ = s.recvfrom(4096)
    finally:
        s.close()
    if len(data) < 6 or data[4] != 0x49:
        raise ValueError("unexpected A2S reply")
    pos = 6  # header (4) + typ (1) + protokoll (1)
    for _ in range(4):  # name, map, folder, game
        pos = data.index(b"\x00", pos) + 1
    pos += 2  # app id (short)
    return data[pos]


def find_buildid(node):
    if isinstance(node, dict):
        pub = node.get("branches", {}).get("public") if isinstance(node.get("branches"), dict) else None
        if isinstance(pub, dict) and "buildid" in pub:
            return str(pub["buildid"])
        for value in node.values():
            found = find_buildid(value)
            if found:
                return found
    return None


def get_json(url):
    req = urllib.request.Request(url, headers={"User-Agent": "lxc-gameserver-auto-update"})
    with urllib.request.urlopen(req, timeout=20) as resp:
        return json.load(resp)


def main(argv):
    if len(argv) >= 3 and argv[0] == "a2s":
        for port in argv[2].split(","):
            try:
                print(a2s_players(argv[1], int(port)))
                return 0
            except (OSError, ValueError, IndexError):
                continue
        return 1
    if len(argv) == 2 and argv[0] == "steam-latest":
        build = find_buildid(get_json("https://api.steamcmd.net/v1/info/" + argv[1]))
        if build:
            print(build)
            return 0
        return 1
    if len(argv) == 1 and argv[0] == "mc-latest":
        print(get_json("https://launchermeta.mojang.com/mc/game/version_manifest.json")["latest"]["release"])
        return 0
    print("usage: gsquery.py a2s HOST PORTS | steam-latest APPID | mc-latest", file=sys.stderr)
    return 2


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except Exception as exc:  # nätverksfel osv.
        print("gsquery: %s" % exc, file=sys.stderr)
        sys.exit(1)
PYEOF
chmod +x "$LIB_DIR/gsquery.py"

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
mk auto-update 'gs_autoupdate "$@"'
mk server-help gs_help

# Behåll timern påslagen efter en ominstallation om auto-update redan var på
if grep -q '^AUTO_UPDATE=on' /etc/gameserver-autoupdate.conf 2>/dev/null
then
  systemctl enable --now gameserver-autoupdate.timer > /dev/null 2>&1 || true
fi

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

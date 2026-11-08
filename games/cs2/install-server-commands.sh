#!/bin/bash
# install-server-commands.sh for cs2
#
# GENERATED FILE - do not edit. Edit lib/ and games/<game>/profile.conf, then run:
#   python3 tools/build-commands.py
#
# Installerar samma serverkommandon på varje spel-LXC (se docs/commands.md). Alla heter
# gameserver-<kommando>: status, serverlog, start, stop, restart, update, versions, backup,
# password, logs, auto-update, update-lxc, check, help. Äldre namn utan prefix tas bort.
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
      echo "Ingen profil för '$1' i den här filen (den är för cs2)."
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
    echo "  1) cs2"
    read -r -p "Välj nummer eller namn: " ANS
    case "$ANS" in
      1|cs2) GAME=cs2 ;;
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

# nano: gameserver-password; python3: gameserver-auto-update; git: gameserver-update-lxc
PKGS=()
command -v nano > /dev/null 2>&1 || PKGS+=(nano)
command -v python3 > /dev/null 2>&1 || PKGS+=(python3)
command -v git > /dev/null 2>&1 || PKGS+=(git)
if [ "${#PKGS[@]}" -gt 0 ]
then
  if ! { apt-get update -qq && apt-get install -y "${PKGS[@]}"; }
  then
    echo "Varning: kunde inte installera ${PKGS[*]}. gameserver-password behöver nano, gameserver-auto-update python3, gameserver-update-lxc git."
  fi
fi

mkdir -p "$LIB_DIR" "$STATE_DIR"

cat > "$LIB_DIR/common.sh" <<'GS_EOF_COMMON'
#!/bin/bash
# shellcheck disable=SC1090
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
    # -t bara med terminal, annars avbryts "ssh host serverlog" med "the input device is not a TTY"
    if [ -t 1 ]
    then
      docker exec -t "$CONTAINER" tail -f "$GAME_LOG"
    else
      docker exec "$CONTAINER" tail -f "$GAME_LOG"
    fi
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
    echo "The image updates the game itself; run 'gameserver-update' to pull a newer image."
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
# En systemd-timer kör "gameserver-auto-update run" varje minut när auto-update är på (bara om servern körs):
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
  AUTO_UPDATE=on
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
# Auto-update settings. Change them with: gameserver-auto-update
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
    *) echo "Usage: gameserver-auto-update [on|off|status|log]"; return 1 ;;
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

# Alla kommandon som installeras i /usr/local/bin (namn|argument|beskrivning|exempel).
# Alla börjar med "gameserver-" så att de aldrig krockar med systemets eller andra verktygs kommandon
# (t.ex. /usr/bin/update från community-scripts). Skriv gameserver- och tryck Tab.
GS_COMMANDS=(
  "gameserver-status||server status + last lines from the server log|gameserver-status"
  "gameserver-serverlog||live tail of the server log (Ctrl+C to quit)|gameserver-serverlog"
  "gameserver-start||start the game server|gameserver-start"
  "gameserver-stop||stop the game server|gameserver-stop"
  "gameserver-restart||restart the game server|gameserver-restart"
  "gameserver-update||backup, update the game (image/files), restart|gameserver-update"
  "gameserver-versions||installed vs latest game version|gameserver-versions"
  "gameserver-backup||backup of the savegame to DIR/backups|gameserver-backup"
  "gameserver-password||edit all passwords in nano, then run gameserver-restart|gameserver-password"
  "gameserver-logs||live container/system logs|gameserver-logs"
  "gameserver-auto-update|[on|off|status|log]|automatic game updates; no argument = asks 3 questions|gameserver-auto-update status"
  "gameserver-update-lxc|[--dry-run|--force|--rollback [DIR]|--help]|update these commands from the Git repository, data is kept|gameserver-update-lxc --dry-run"
  "gameserver-check||check for command conflicts and startup-file problems|gameserver-check"
  "gameserver-help|[--full]|this list; --full adds arguments and examples|gameserver-help --full"
)

# Namn från äldre versioner (utan prefix). Installern tar bort dem om de är våra egna stubbar.
GS_OLD_COMMANDS="start stop restart status serverlog logs update update-game versions backup password passwords lösenord auto-update update-lxc server-check server-help enshrouded-help"

gs_command_names() {
  local E
  for E in "${GS_COMMANDS[@]}"
  do
    echo "${E%%|*}"
  done
}

gs_help() {
  local E NAME REST ARGS DESC EX
  echo
  echo "=== ${GAME^} commands ($MODE) ==="
  for E in "${GS_COMMANDS[@]}"
  do
    NAME=${E%%|*}; REST=${E#*|}
    ARGS=${REST%%|*}; REST=${REST#*|}
    DESC=${REST%%|*}; EX=${REST#*|}
    if [ "${1:-}" = --full ]
    then
      printf '  %-22s %s\n' "$NAME" "$DESC"
      [ -n "$ARGS" ] && printf '  %-22s   arguments: %s\n' "" "$ARGS"
      printf '  %-22s   example:   %s\n' "" "$EX"
    else
      printf '  %-22s - %s\n' "$NAME" "$DESC"
    fi
  done
  echo "  Type gameserver- and press Tab to see them all."
  echo
}

# gameserver-check: hittar alias/funktioner som skuggar kommandona, gamla startrader och
# skal som skriver ut något när de inte är interaktiva.
gs_check() {
  local N T P OUT CNT F BAD=0
  # Testskalen ska inte skriva till .bash_history
  local HISTFILE=/dev/null
  export HISTFILE
  echo "=== Commands (as an interactive root shell sees them) ==="
  for N in $(gs_command_names)
  do
    T=$(GS_NO_BANNER=1 bash -ic "type -t '$N'" 2>/dev/null < /dev/null | tail -n1)
    P=$(type -P "$N" 2>/dev/null)
    if [ "$T" = file ] && [ "$P" = "/usr/local/bin/$N" ]
    then
      continue
    fi
    BAD=1
    case "$T" in
      alias) echo "  CONFLICT $N: is an alias: $(GS_NO_BANNER=1 bash -ic "alias '$N'" 2>/dev/null < /dev/null | tail -n1)" ;;
      function) echo "  CONFLICT $N: is a shell function (defined in a startup file), /usr/local/bin/$N is not used" ;;
      builtin|keyword) echo "  CONFLICT $N: is a bash $T" ;;
      file) echo "  CONFLICT $N: runs $P instead of /usr/local/bin/$N" ;;
      *) echo "  MISSING  $N: not found (re-run install-server-commands.sh or gameserver-update-lxc)" ;;
    esac
  done
  [ "$BAD" = 0 ] && echo "  OK: every command runs /usr/local/bin/<name>"

  echo
  echo "=== Old command names and other tools ==="
  CNT=0
  for N in $GS_OLD_COMMANDS
  do
    if [ -e "/usr/local/bin/$N" ] && grep -qE '^(\. /usr/local/lib/gameserver/common.sh|exec bash /usr/local/lib/gameserver/update-lxc.sh)' "/usr/local/bin/$N" 2>/dev/null
    then
      BAD=1; CNT=1
      echo "  OLD     /usr/local/bin/$N is a leftover from an older version (re-run gameserver-update-lxc)"
    fi
  done
  for F in /usr/bin/update /usr/local/bin/update /etc/profile.d/*.sh
  do
    if [ -f "$F" ] && grep -qi 'community-scripts' "$F" 2>/dev/null
    then
      CNT=1
      echo "  INFO    $F comes from the Proxmox VE community-scripts helper (not used by this project)."
      echo "          It is left alone. Remove it yourself if you no longer want it: mv $F /root/$(basename "$F").community-scripts.bak"
    fi
  done
  [ "$CNT" = 0 ] && echo "  OK: no old command names, no community-scripts files"

  echo
  echo "=== Startup files ==="
  for F in /etc/bash.bashrc /etc/profile /etc/profile.d/*.sh /root/.bashrc /root/.bash_aliases /root/.profile /root/.bash_profile
  do
    [ -f "$F" ] || continue
    if ! bash -n "$F" 2>/dev/null
    then
      BAD=1
      echo "  SYNTAX ERROR in $F: $(bash -n "$F" 2>&1 | head -n1)"
    fi
    OUT=$(grep -nE 'CUSTOM_CMDS|GAMESERVER_COMMANDS|enshrouded-help|alias help=' "$F" 2>/dev/null | grep -v 'removed by install-server-commands.sh')
    if [ -n "$OUT" ]
    then
      BAD=1
      echo "  OLD BANNER/ALIAS in $F:"
      echo "$OUT" | sed 's/^/    line /'
    fi
    for N in $(gs_command_names) help
    do
      if grep -nE "^[[:space:]]*(alias[[:space:]]+${N}=|(function[[:space:]]+)?${N}[[:space:]]*\(\))" "$F" > /dev/null 2>&1
      then
        BAD=1
        echo "  $F defines '$N':"
        grep -nE "^[[:space:]]*(alias[[:space:]]+${N}=|(function[[:space:]]+)?${N}[[:space:]]*\(\))" "$F" | sed 's/^/    line /'
      fi
    done
  done

  echo
  echo "=== Shell start ==="
  CNT=$(echo exit | bash -i 2>/dev/null | grep -c ' commands (')
  echo "  interactive shell (bash):      command list shown $CNT time(s) (expected 1)"
  [ "$CNT" = 1 ] || BAD=1
  CNT=$(echo exit | bash -il 2>/dev/null | grep -c ' commands (')
  echo "  interactive login (bash -l):   command list shown $CNT time(s) (expected 1)"
  [ "$CNT" = 1 ] || BAD=1
  OUT=$(bash -c true 2>&1; bash -lc true 2>&1)
  if [ -n "$OUT" ]
  then
    BAD=1
    echo "  NON-INTERACTIVE shells print output (breaks scp/rsync/ssh commands):"
    echo "$OUT" | head -n 5 | sed 's/^/    /'
  else
    echo "  non-interactive (bash -c, bash -lc): silent (expected)"
  fi
  echo
  if [ "$BAD" = 0 ]
  then
    echo "gameserver-check: no problems found."
  else
    echo "gameserver-check: problems found (see above). Nothing was changed."
  fi
  return "$BAD"
}
GS_EOF_COMMON

cat > "$LIB_DIR/gsquery.py" <<'GS_EOF_PY'
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
GS_EOF_PY
chmod +x "$LIB_DIR/gsquery.py"

cat > "$LIB_DIR/shell-init.sh" <<'GS_EOF_INIT'
# shellcheck shell=bash
# /usr/local/lib/gameserver/shell-init.sh
# Visar serverkommandona när ett interaktivt bash-skal startar. Källas (sourced) från
#   /etc/bash.bashrc                 interaktiva skal utan inloggning: "bash", pct enter
#   /etc/profile.d/zz-gameserver.sh  inloggningsskal: ssh, su -, konsol
# Debian/Ubuntu läser båda i ett inloggningsskal; spärren nedan gör att listan bara visas en gång
# per skal. Spärren exporteras inte, så ett nytt "bash" visar listan igen.
# Gör ingenting (och skriver ingenting) i skript, cron, "ssh host kommando" och "bash -c".
# Stäng av med GS_NO_BANNER=1.

# Bara bash
[ -n "${BASH_VERSION:-}" ] || return 0
# Bara interaktiva skal, inte "bash -c '...'" och inte om redan visad i det här skalet
case $- in
  *i*) ;;
  *) return 0 ;;
esac
[ -z "${BASH_EXECUTION_STRING:-}" ] || return 0
[ -z "${GS_BANNER_SHOWN:-}" ] || return 0
[ -z "${GS_NO_BANNER:-}" ] || return 0
GS_BANNER_SHOWN=1

if [ -x /usr/local/bin/gameserver-help ]
then
  /usr/local/bin/gameserver-help || true
fi
GS_EOF_INIT

# update-lxc.sh skrivs till en ny fil som sedan byter plats, så att en körande gameserver-update-lxc inte påverkas
cat > "$LIB_DIR/.update-lxc.sh.new" <<'GS_EOF_UPDATE'
#!/bin/bash
# shellcheck disable=SC1090
# gameserver-update-lxc: updates this LXC's server commands and game compose file from the Git repository.
#
# Application files (from Git, replaced only after a verified backup):
#   /opt/<game>/docker-compose.yml, /opt/<game>/install-server-commands.sh and everything that
#   install-server-commands.sh generates (/usr/local/lib/gameserver, /usr/local/bin commands,
#   systemd units, the shell startup hook).
# Never replaced or deleted (only backed up):
#   game data (every bind-mounted folder of the compose file), /opt/<game>/passwords.env,
#   /opt/<game>/.env, /etc/gameserver.conf (only missing keys are added),
#   /etc/gameserver-autoupdate.conf, /opt/<game>/backups.
#
# Exit codes:
#   0 updated, or already up to date        1 error before anything was changed
#   2 stopped: needs a decision (local changes, branch, data migration); nothing changed
#   3 update failed and was rolled back       4 rollback failed: check manually (backup path printed)
#
# Usage: gameserver-update-lxc [--dry-run] [--force] [--saves-only] [--allow-volume-change] [--yes]
#        gameserver-update-lxc --rollback [BACKUP_DIR]
#        gameserver-update-lxc --help
#
# The whole script is one function (main) so that it can safely replace its own installed copy.

main() {
  set -o pipefail
  umask 022
  local -a ORIG_ARGS=("$@")

  local CONF=/etc/gameserver.conf
  local REPO_CONF=/etc/gameserver-repo.conf
  local STATE_DIR=/var/lib/gameserver
  local MANIFEST=$STATE_DIR/deployed.sha256
  local LOG=/var/log/gameserver-update-lxc.log
  local LOCK=/run/gameserver-update-lxc.lock
  local AU_LOCK=/run/gameserver-autoupdate.lock

  local DRY_RUN=0 FORCE=0 SAVES_ONLY=0 ALLOW_VOLUMES=0 ASSUME_YES=0 ROLLBACK=0 ROLLBACK_DIR=
  while [ $# -gt 0 ]
  do
    case "$1" in
      --dry-run|-n) DRY_RUN=1 ;;
      --force) FORCE=1 ;;
      --saves-only) SAVES_ONLY=1 ;;
      --allow-volume-change) ALLOW_VOLUMES=1 ;;
      --yes|-y) ASSUME_YES=1 ;;
      --rollback)
        ROLLBACK=1
        if [ -n "${2:-}" ] && [ "${2#-}" = "$2" ]
        then
          ROLLBACK_DIR=$2
          shift
        fi
        ;;
      --help|-h) ul_usage; return 0 ;;
      *) echo "gameserver-update-lxc: unknown option: $1 (see gameserver-update-lxc --help)" >&2; return 1 ;;
    esac
    shift
  done

  if [ "$(id -u)" -ne 0 ]
  then
    echo "gameserver-update-lxc: run as root." >&2
    return 1
  fi

  # All output also goes to the log (once: a re-executed target version already writes into it)
  mkdir -p "$(dirname "$LOG")" "$STATE_DIR"
  if [ -n "${GS_UPDATE_LXC_REEXEC:-}" ]
  then
    rm -f -- "${BASH_SOURCE[0]}"
    echo "  (now running gameserver-update-lxc from the target version)"
  else
    exec > >(tee -a "$LOG") 2>&1
    echo
    echo "===== gameserver-update-lxc $(date '+%Y-%m-%d %H:%M:%S') ($*) ====="
  fi

  exec 8> "$LOCK"
  if ! flock -n 8
  then
    echo "gameserver-update-lxc is already running."
    return 1
  fi

  # ------------------------------------------------------------ 1. installation
  ul_step "1. Current installation"
  if [ ! -f "$CONF" ]
  then
    echo "  $CONF is missing: this LXC was not installed by install-server-commands.sh."
    echo "  It needs a manual migration; nothing was changed."
    return 2
  fi
  local GAME MODE DIR CONTAINER
  # shellcheck disable=SC1090
  GAME=$(. "$CONF"; echo "$GAME")
  MODE=$(. "$CONF"; echo "$MODE")
  DIR=$(. "$CONF"; echo "$DIR")
  CONTAINER=$(. "$CONF"; echo "$CONTAINER")
  echo "  game=$GAME mode=$MODE dir=$DIR container=$CONTAINER"
  if [ "$MODE" != docker ]
  then
    echo "  MODE=$MODE: gameserver-update-lxc only supports MODE=docker so far. Nothing was changed."
    return 2
  fi
  if [ -z "$GAME" ] || [ ! -d "$DIR" ]
  then
    echo "  GAME or DIR in $CONF is wrong. Nothing was changed."
    return 1
  fi

  local REPO_URL=https://github.com/klangche/LXC-gameserver.git REPO_BRANCH=main REPO_DIR=/opt/lxc-gameserver
  local BACKUP_ROOT=/var/backups/gameserver
  if [ -f "$REPO_CONF" ]
  then
    # shellcheck disable=SC1090
    . "$REPO_CONF"
  fi
  echo "  repository: $REPO_URL (branch $REPO_BRANCH) in $REPO_DIR"

  if [ "$ROLLBACK" = 1 ]
  then
    ul_rollback "$ROLLBACK_DIR"
    return $?
  fi

  local P
  for P in git docker tar sha256sum flock
  do
    if ! command -v "$P" > /dev/null 2>&1
    then
      echo "  '$P' is missing. Install it first, e.g.: apt-get install -y $P"
      return 1
    fi
  done

  # ------------------------------------------------------------ 2. connectivity
  ul_step "2. Git remote"
  if ! timeout 60 git ls-remote --exit-code "$REPO_URL" "refs/heads/$REPO_BRANCH" > /dev/null
  then
    echo "  Cannot reach $REPO_URL or branch '$REPO_BRANCH' does not exist. Nothing was changed."
    return 1
  fi
  echo "  reachable, branch $REPO_BRANCH exists"

  # ------------------------------------------------------------ 3. fetch
  ul_step "3. Repository clone"
  local FIRST_CLONE=0
  if [ ! -e "$REPO_DIR" ]
  then
    if [ "$DRY_RUN" = 1 ]
    then
      echo "  $REPO_DIR does not exist; using a temporary clone for the preview."
      REPO_DIR=$(mktemp -d /tmp/update-lxc-preview.XXXXXX)
    fi
    echo "  + git clone --branch $REPO_BRANCH $REPO_URL $REPO_DIR"
    git clone -q --branch "$REPO_BRANCH" "$REPO_URL" "$REPO_DIR" || { echo "  clone failed"; return 1; }
    FIRST_CLONE=1
  fi
  if [ ! -d "$REPO_DIR/.git" ]
  then
    echo "  $REPO_DIR exists but is not a Git clone. Move it away or set REPO_DIR in $REPO_CONF."
    return 2
  fi
  local ORIGIN BRANCH
  ORIGIN=$(git -C "$REPO_DIR" remote get-url origin 2>/dev/null)
  BRANCH=$(git -C "$REPO_DIR" symbolic-ref --short -q HEAD)
  if [ "${ORIGIN%.git}" != "${REPO_URL%.git}" ]
  then
    echo "  origin of $REPO_DIR is '$ORIGIN', expected '$REPO_URL'. Refusing to update from an unexpected remote."
    return 2
  fi
  if [ "$BRANCH" != "$REPO_BRANCH" ]
  then
    echo "  $REPO_DIR is on branch '${BRANCH:-detached HEAD}', expected '$REPO_BRANCH'. Refusing to continue."
    return 2
  fi
  if [ -n "$(git -C "$REPO_DIR" status --porcelain)" ]
  then
    echo "  $REPO_DIR has local changes (they would be lost or mixed in):"
    git -C "$REPO_DIR" status --short | sed 's/^/    /'
    echo "  Commit/stash them or move them away. Nothing was changed."
    return 2
  fi
  echo "  + git fetch origin $REPO_BRANCH"
  git -C "$REPO_DIR" fetch -q origin "$REPO_BRANCH" || { echo "  fetch failed"; return 1; }

  # ------------------------------------------------------------ 4. versions
  ul_step "4. Versions"
  local CUR TARGET
  CUR=$(git -C "$REPO_DIR" rev-parse HEAD)
  TARGET=$(git -C "$REPO_DIR" rev-parse "origin/$REPO_BRANCH")
  echo "  clone:    $(git -C "$REPO_DIR" log -1 --format='%h %cd %s' --date=short "$CUR")"
  echo "  target:   $(git -C "$REPO_DIR" log -1 --format='%h %cd %s' --date=short "$TARGET")"
  if [ -f "$STATE_DIR/deployed.rev" ]
  then
    echo "  deployed: $(cat "$STATE_DIR/deployed.rev")"
  else
    echo "  deployed: unknown (first gameserver-update-lxc on this LXC)"
  fi
  if ! git -C "$REPO_DIR" merge-base --is-ancestor "$CUR" "$TARGET"
  then
    echo "  The target is not a fast-forward of the clone (history was rewritten?). Refusing to continue."
    return 2
  fi
  if ! git -C "$REPO_DIR" cat-file -e "$TARGET:games/$GAME/install-server-commands.sh" 2>/dev/null
  then
    echo "  The target has no games/$GAME/install-server-commands.sh. Refusing to continue."
    return 2
  fi
  # grep -c läser allt (grep -q kan ge SIGPIPE till git, och pipefail ser det som fel)
  if ! git -C "$REPO_DIR" show "$TARGET:games/$GAME/install-server-commands.sh" | grep -c 'update-lxc' > /dev/null
  then
    echo "  The target version does not contain gameserver-update-lxc (older than this one). Refusing to downgrade."
    return 2
  fi

  # Resten görs av update-lxc.sh från målversionen, så att dess kontroller och steg gäller direkt
  if [ -z "${GS_UPDATE_LXC_REEXEC:-}" ]
  then
    local NEWSELF
    NEWSELF=$(mktemp /tmp/gameserver-update-lxc-target.XXXXXX)
    if git -C "$REPO_DIR" show "$TARGET:lib/update-lxc.sh" > "$NEWSELF" 2>/dev/null && bash -n "$NEWSELF" 2>/dev/null \
      && ! cmp -s "$NEWSELF" "${BASH_SOURCE[0]}"
    then
      echo "  The target has a newer gameserver-update-lxc; continuing with that version."
      exec 8>&-
      GS_UPDATE_LXC_REEXEC=1 exec bash "$NEWSELF" "${ORIG_ARGS[@]}"
    fi
    rm -f -- "$NEWSELF"
  fi

  # ------------------------------------------------------------ 5. local changes
  ul_step "5. Compare installed files with the repository"
  local WORK
  WORK=$(mktemp -d /tmp/update-lxc.XXXXXX)
  local -a FILES=(docker-compose.yml install-server-commands.sh)
  local F NEEDS=0 BLOCKED=0 COMPOSE_CHANGED=0 DEPLOYED_SUM TARGET_SUM KNOWN_SUM
  for F in "${FILES[@]}"
  do
    git -C "$REPO_DIR" show "$TARGET:games/$GAME/$F" > "$WORK/$F" || { echo "  cannot read $F from the target"; return 1; }
    TARGET_SUM=$(ul_sum "$WORK/$F")
    if [ ! -f "$DIR/$F" ]
    then
      echo "  $F: missing, will be added"
      NEEDS=1
      [ "$F" = docker-compose.yml ] && COMPOSE_CHANGED=1
      continue
    fi
    DEPLOYED_SUM=$(ul_sum "$DIR/$F")
    if [ "$DEPLOYED_SUM" = "$TARGET_SUM" ]
    then
      echo "  $F: up to date"
      continue
    fi
    NEEDS=1
    [ "$F" = docker-compose.yml ] && COMPOSE_CHANGED=1
    KNOWN_SUM=$(awk -v f="$DIR/$F" '$2 == f {print $1}' "$MANIFEST" 2>/dev/null)
    if [ -n "$KNOWN_SUM" ] && [ "$KNOWN_SUM" = "$DEPLOYED_SUM" ]
    then
      echo "  $F: changed in the repository, not changed locally -> will be updated"
    elif [ "$FORCE" = 1 ]
    then
      echo "  $F: differs and was not deployed by gameserver-update-lxc (local change or older version)."
      echo "      --force: it will be replaced; the current file is kept as $DIR/$F.local-<time>"
      diff -u "$DIR/$F" "$WORK/$F" | sed 's/^/      /' | head -n 80
    else
      BLOCKED=1
      echo "  $F: differs and was not deployed by gameserver-update-lxc (local change or older version):"
      diff -u --label "installed $DIR/$F" --label "repository $F" "$DIR/$F" "$WORK/$F" | sed 's/^/      /' | head -n 120
    fi
  done

  # Lokala ändringar i de genererade filerna (common.sh osv.)
  if [ -f "$STATE_DIR/generated.sha256" ] && ! sha256sum --quiet -c "$STATE_DIR/generated.sha256" > "$WORK/gen.check" 2>&1
  then
    if [ "$FORCE" = 1 ]
    then
      echo "  Generated files were edited by hand (--force: they are backed up and regenerated):"
    else
      BLOCKED=1
      echo "  Generated files were edited by hand:"
    fi
    sed 's/^/      /' "$WORK/gen.check"
  fi

  # Datamigrering: ändrade volymer eller containernamn betyder att speldata flyttar
  if [ "$COMPOSE_CHANGED" = 1 ] && [ -f "$DIR/docker-compose.yml" ]
  then
    if ! diff <(ul_compose_layout "$DIR/docker-compose.yml") <(ul_compose_layout "$WORK/docker-compose.yml") > "$WORK/layout.diff"
    then
      echo
      echo "  GAME DATA MIGRATION: the new compose file changes where the game data lives:"
      sed 's/^/      /' "$WORK/layout.diff"
      if [ "$ALLOW_VOLUMES" = 1 ]
      then
        echo "  --allow-volume-change given: continuing (the old folders are NOT moved or deleted)."
      else
        echo "  This is not an application update. Move the data by hand (see the README),"
        echo "  then run: gameserver-update-lxc --allow-volume-change"
        BLOCKED=1
      fi
    fi
  fi

  # Nya lösenordsnycklar i mallen
  local K MISSING_KEYS=
  if git -C "$REPO_DIR" show "$TARGET:games/$GAME/passwords.env" > "$WORK/passwords.env.template" 2>/dev/null
  then
    for K in $(grep -oE '^[A-Za-z_][A-Za-z0-9_]*=' "$WORK/passwords.env.template" | tr -d '=')
    do
      grep -q "^$K=" "$DIR/passwords.env" 2>/dev/null || MISSING_KEYS="$MISSING_KEYS $K"
    done
  fi
  if [ -n "$MISSING_KEYS" ]
  then
    echo "  passwords.env lacks:$MISSING_KEYS -> add them with 'gameserver-password' after the update (not done automatically)"
  fi

  local REV_CHANGED=0
  [ "$CUR" != "$TARGET" ] && REV_CHANGED=1
  [ "$(cat "$STATE_DIR/deployed.rev" 2>/dev/null | cut -d' ' -f1)" != "$TARGET" ] && REV_CHANGED=1

  if [ "$BLOCKED" = 1 ]
  then
    echo
    echo "Stopped: the differences above need your decision. Nothing was changed."
    echo "  Keep your version:   leave it; or copy your change into the repository first."
    echo "  Take the repository: gameserver-update-lxc --force   (your files are kept as *.local-<time>)"
    [ "$FIRST_CLONE" = 1 ] && [ "$DRY_RUN" = 0 ] && echo "  (The clone in $REPO_DIR was created and is kept.)"
    return 2
  fi
  if [ "$NEEDS" = 0 ] && [ "$REV_CHANGED" = 0 ]
  then
    echo
    echo "Already up to date ($(git -C "$REPO_DIR" log -1 --format=%h "$TARGET")). Nothing to do."
    return 0
  fi

  # ------------------------------------------------------------ plan
  local RUNNING=0
  [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null)" = true ] && RUNNING=1
  ul_step "Plan"
  echo "  - back up configuration + $([ "$SAVES_ONLY" = 1 ] && echo "savegame only (--saves-only)" || echo "all game data folders") to $BACKUP_ROOT/<time>"
  echo "  - fast-forward $REPO_DIR to $(git -C "$REPO_DIR" log -1 --format=%h "$TARGET")"
  echo "  - install the changed files into $DIR, keep passwords.env, .env and all data"
  echo "  - run $DIR/install-server-commands.sh $GAME (regenerates the commands, keeps settings)"
  if [ "$COMPOSE_CHANGED" = 1 ]
  then
    if [ "$RUNNING" = 1 ]
    then
      echo "  - docker-compose.yml changed: the server is stopped for the backup and started again"
    else
      echo "  - docker-compose.yml changed: the server is stopped and stays stopped"
    fi
  else
    echo "  - the game server is not restarted (no compose change)"
  fi
  if [ "$DRY_RUN" = 1 ]
  then
    echo
    echo "Dry run: nothing was changed."
    return 0
  fi
  if [ "$ASSUME_YES" = 0 ] && [ -t 0 ]
  then
    local A
    read -r -p "Continue? [y/N]: " A
    case "$A" in y|Y|yes|j|J|ja) ;; *) echo "Cancelled. Nothing was changed."; return 2 ;; esac
  fi

  # Vänta in en pågående auto-update och blockera nya under tiden
  exec 9> "$AU_LOCK"
  if ! flock -w 900 9
  then
    echo "An auto-update has been running for 15 minutes. Try again later. Nothing was changed."
    return 1
  fi

  # ------------------------------------------------------------ 6. backup
  ul_step "6. Backup"
  if [ "$COMPOSE_CHANGED" = 1 ] && [ "$RUNNING" = 1 ]
  then
    echo "  + docker compose stop (consistent savegame)"
    (cd "$DIR" && docker compose stop) || { echo "  could not stop the server. Nothing was changed."; return 1; }
  fi
  local BK
  if ! BK=$(ul_backup)
  then
    echo "  BACKUP FAILED. Nothing was changed."
    ul_start_if "$RUNNING" "$COMPOSE_CHANGED"
    return 1
  fi
  echo "  backup verified: $BK"
  echo "$BK" > "$STATE_DIR/last-update-backup"

  # ------------------------------------------------------------ 7-10. apply
  ul_step "7. Apply"
  echo "$BK $CUR" > "$STATE_DIR/update.inprogress"
  if ! ul_apply
  then
    echo
    echo "UPDATE FAILED. Rolling back from $BK ..."
    if ul_restore "$BK" && git -C "$REPO_DIR" checkout -q -B "$REPO_BRANCH" "$CUR"
    then
      ul_start_if "$RUNNING" 1
      rm -f "$STATE_DIR/update.inprogress"
      echo "Rolled back to the state before the update. Backup: $BK"
      return 3
    fi
    echo "ROLLBACK FAILED. Restore by hand: gameserver-update-lxc --rollback $BK"
    return 4
  fi

  # ------------------------------------------------------------ 11-12. start + verify
  ul_step "11. Start"
  ul_start_if "$RUNNING" "$COMPOSE_CHANGED"
  ul_step "12. Verify"
  if ! ul_verify
  then
    echo
    echo "VERIFICATION FAILED. Rolling back from $BK ..."
    if ul_restore "$BK" && git -C "$REPO_DIR" checkout -q -B "$REPO_BRANCH" "$CUR"
    then
      (cd "$DIR" && docker compose up -d --remove-orphans) > /dev/null 2>&1
      [ "$RUNNING" = 1 ] || (cd "$DIR" && docker compose stop) > /dev/null 2>&1
      rm -f "$STATE_DIR/update.inprogress"
      echo "Rolled back. Backup: $BK"
      return 3
    fi
    echo "ROLLBACK FAILED. Restore by hand: gameserver-update-lxc --rollback $BK"
    return 4
  fi
  rm -f "$STATE_DIR/update.inprogress"

  # ------------------------------------------------------------ 13. report
  ul_step "13. Result"
  echo "  Updated to $(git -C "$REPO_DIR" log -1 --format='%h %s' "$TARGET")"
  echo "  Backup: $BK   (undo: gameserver-update-lxc --rollback $BK)"
  [ -n "$MISSING_KEYS" ] && echo "  To do: add$MISSING_KEYS to passwords.env with 'gameserver-password', then 'gameserver-restart'"
  echo "  Log: $LOG"
  return 0
}

ul_usage() {
  cat <<'EOF'
gameserver-update-lxc - update the server commands of this LXC from the Git repository; game data is kept.

  gameserver-update-lxc                 show the plan, ask, back up, update, verify
  gameserver-update-lxc --dry-run       only show what would change (also: -n)
  gameserver-update-lxc --yes           do not ask before applying (for scripts)
  gameserver-update-lxc --force         replace files that differ from the repository; your versions
                             are kept next to them as <file>.local-<time>
  gameserver-update-lxc --saves-only    back up only the savegame instead of all game data folders
                             (for big games when the disk is too small for a full backup)
  gameserver-update-lxc --allow-volume-change
                             continue although the compose file moves the game data
  gameserver-update-lxc --rollback [DIR]
                             restore commands and configuration from a backup made by
                             gameserver-update-lxc (default: the last one). Game data is NOT restored
                             automatically; the command prints how to do that.

Settings: /etc/gameserver-repo.conf (REPO_URL, REPO_BRANCH, REPO_DIR, BACKUP_ROOT)
Log: /var/log/gameserver-update-lxc.log
Exit codes: 0 ok, 1 error (nothing changed), 2 needs a decision (nothing changed),
            3 failed and rolled back, 4 rollback failed
EOF
}

ul_step() {
  echo
  echo "--- $1"
}

ul_sum() {
  sha256sum "$1" | cut -d' ' -f1
}

# Det som avgör var speldata ligger: containernamn och volymer
ul_compose_layout() {
  grep -E '^[[:space:]]*(container_name:|- \.?/?[^:]+:/|network_mode:)' "$1" | sed 's/[[:space:]]*$//'
}

# Källmappar för alla bind-mounts (relativa till DIR)
ul_data_dirs() {
  grep -oE '^[[:space:]]*- \.?/[^:]+:/' "$DIR/docker-compose.yml" | sed -E 's/^[[:space:]]*- //; s/:\/$//' | sort -u
}

# Skapar och verifierar backupen, skriver ut sökvägen
ul_backup() {
  local STAMP BK SAVE_SUB DATA_DIR NEED AVAIL D
  STAMP=$(date +%Y%m%d-%H%M%S)
  BK="$BACKUP_ROOT/$STAMP"
  mkdir -p "$BK" || return 1
  chmod 700 "$BACKUP_ROOT" "$BK"

  # Konfiguration och programfiler (absoluta sökvägar, med ägare/rättigheter/symlänkar)
  local -a CFG=()
  for D in /etc/gameserver.conf /etc/gameserver-autoupdate.conf /etc/gameserver-repo.conf \
    /usr/local/lib/gameserver /etc/systemd/system/gameserver-autoupdate.service \
    /etc/systemd/system/gameserver-autoupdate.timer /etc/bash.bashrc /etc/profile.d/zz-gameserver.sh \
    /root/.bashrc /root/.profile "$STATE_DIR" \
    "$DIR/docker-compose.yml" "$DIR/install-server-commands.sh" "$DIR/passwords.env" "$DIR/.env"
  do
    [ -e "$D" ] && CFG+=("${D#/}")
  done
  for D in $(gs_cmd_list) $(gs_old_cmd_list)
  do
    [ -e "/usr/local/bin/$D" ] && CFG+=("usr/local/bin/$D")
  done
  tar -C / --numeric-owner -cpzf "$BK/config.tar.gz" "${CFG[@]}" >&2 || return 1
  # Vilka programfiler fanns före uppdateringen (nya tas bort vid en återställning)
  ul_app_files > "$BK/app-files.before"

  # Speldata
  local -a DATA=()
  if [ "$SAVES_ONLY" = 1 ]
  then
    # shellcheck disable=SC1090
    DATA_DIR=$(. "$CONF"; echo "$DATA_DIR")
    # shellcheck disable=SC1090
    SAVE_SUB=$(. "$CONF"; echo "$SAVE_SUB")
    DATA=("$DATA_DIR/$SAVE_SUB")
  else
    while IFS= read -r D
    do
      D=${D#./}
      [ -e "$DIR/$D" ] && DATA+=("$D")
    done < <(ul_data_dirs)
  fi
  if [ "${#DATA[@]}" -gt 0 ]
  then
    NEED=$( (cd "$DIR" && du -sk --exclude=./backups "${DATA[@]}") | awk '{s+=$1} END{print s+0}')
    AVAIL=$(df -Pk "$BK" | awk 'NR==2{print $4}')
    echo "  game data: ${DATA[*]} ($((NEED / 1024)) MB, free: $((AVAIL / 1024)) MB)" >&2
    if [ "$AVAIL" -lt $((NEED + NEED / 10 + 102400)) ]
    then
      echo "  Not enough free disk space for the game data backup." >&2
      echo "  Free space, choose another BACKUP_ROOT in /etc/gameserver-repo.conf, or use --saves-only." >&2
      return 1
    fi
    if ! tar -C "$DIR" --numeric-owner -cpzf "$BK/gamedata.tar.gz" "${DATA[@]}" >&2
    then
      echo "  tar could not read the game data completely (a running server writing files?)." >&2
      echo "  Run 'gameserver-stop' first and then gameserver-update-lxc again, or use --saves-only." >&2
      return 1
    fi
    (cd "$DIR" && find "${DATA[@]}" -xdev \( -type f -o -type l \) | LC_ALL=C sort) > "$BK/gamedata.files"
  else
    echo "  WARNING: no game data folder found in the compose file" >&2
  fi

  # Verifiera: läsbar, komplett, med kontrollsummor
  local T
  for T in "$BK"/*.tar.gz
  do
    gzip -t "$T" || return 1
    tar -tzf "$T" > "$T.list" || return 1
    [ -s "$T.list" ] || return 1
  done
  if [ -f "$BK/gamedata.files" ]
  then
    # varje fil i datamapparna måste finnas i arkivet
    local NOT_IN_TAR
    NOT_IN_TAR=$(LC_ALL=C sort "$BK/gamedata.tar.gz.list" | sed 's#/$##' | LC_ALL=C comm -23 "$BK/gamedata.files" -)
    if [ -n "$NOT_IN_TAR" ]
    then
      echo "  backup is missing files:" >&2
      echo "$NOT_IN_TAR" | sed -n '1,5p' >&2
      return 1
    fi
  fi
  (cd "$BK" && sha256sum ./*.tar.gz > SHA256SUMS) || return 1
  {
    echo "created=$(date -Is)"
    echo "game=$GAME"
    echo "dir=$DIR"
    echo "repo_before=$CUR"
    echo "repo_target=$TARGET"
    echo "data=${DATA[*]}"
  } > "$BK/INFO"
  echo "  $(du -sh "$BK" | cut -f1) in $BK" >&2
  echo "$BK"
}

# Programfiler som install-server-commands.sh skapar
ul_app_files() {
  local N
  find /usr/local/lib/gameserver -xdev \( -type f -o -type l \) 2>/dev/null
  for N in $(gs_cmd_list) $(gs_old_cmd_list)
  do
    [ -e "/usr/local/bin/$N" ] && echo "/usr/local/bin/$N"
  done
  for N in /etc/profile.d/zz-gameserver.sh /etc/systemd/system/gameserver-autoupdate.service /etc/systemd/system/gameserver-autoupdate.timer
  do
    [ -e "$N" ] && echo "$N"
  done
}

gs_cmd_list() {
  echo gameserver-start gameserver-stop gameserver-restart gameserver-status gameserver-serverlog gameserver-logs \
    gameserver-update gameserver-versions gameserver-backup gameserver-password gameserver-auto-update \
    gameserver-update-lxc gameserver-check gameserver-help
}

# Namn från äldre versioner: kommer med i backupen och tas bort/återställs vid en återställning
gs_old_cmd_list() {
  echo start stop restart status serverlog logs update update-game versions backup password passwords lösenord auto-update update-lxc server-check server-help
}

# Lägger in filerna och kör den nya installationen
ul_apply() {
  local F STAMP OWN MODEBITS
  STAMP=$(date +%Y%m%d-%H%M%S)
  echo "  + git merge --ff-only origin/$REPO_BRANCH"
  git -C "$REPO_DIR" merge -q --ff-only "origin/$REPO_BRANCH" || return 1

  if [ -f "$WORK/docker-compose.yml" ] && [ "$COMPOSE_CHANGED" = 1 ]
  then
    echo "  + docker compose config (check the new compose file with the existing .env/passwords.env)"
    cp "$WORK/docker-compose.yml" "$DIR/.docker-compose.yml.new"
    if ! (cd "$DIR" && docker compose -f .docker-compose.yml.new config -q)
    then
      rm -f "$DIR/.docker-compose.yml.new"
      echo "  the new compose file is not valid here"
      return 1
    fi
    rm -f "$DIR/.docker-compose.yml.new"
  fi

  for F in "${FILES[@]}"
  do
    if [ -f "$DIR/$F" ] && cmp -s "$DIR/$F" "$WORK/$F"
    then
      continue
    fi
    if [ -f "$DIR/$F" ]
    then
      if [ "$FORCE" = 1 ]
      then
        cp -p "$DIR/$F" "$DIR/$F.local-$STAMP"
        echo "  kept your version: $DIR/$F.local-$STAMP"
      fi
      OWN=$(stat -c '%u:%g' "$DIR/$F")
      MODEBITS=$(stat -c '%a' "$DIR/$F")
    else
      OWN=0:0
      MODEBITS=644
    fi
    echo "  + install $F -> $DIR/$F (owner $OWN, mode $MODEBITS)"
    install -o "${OWN%:*}" -g "${OWN#*:}" -m "$MODEBITS" "$WORK/$F" "$DIR/.$F.new" || return 1
    mv -f "$DIR/.$F.new" "$DIR/$F" || return 1
  done

  echo "  + bash $DIR/install-server-commands.sh $GAME"
  bash "$DIR/install-server-commands.sh" "$GAME" | sed 's/^/    /' || return 1

  # Kom ihåg vad som installerades (för att upptäcka lokala ändringar nästa gång)
  sha256sum "$DIR/docker-compose.yml" "$DIR/install-server-commands.sh" > "$MANIFEST" || return 1
  echo "$TARGET $(date -Is)" > "$STATE_DIR/deployed.rev"
  return 0
}

ul_start_if() {
  local WAS_RUNNING=$1 CHANGED=$2
  if [ "$CHANGED" = 1 ] && [ "$WAS_RUNNING" = 1 ]
  then
    echo "  + docker compose up -d"
    (cd "$DIR" && docker compose up -d) || return 1
  elif [ "$CHANGED" = 1 ]
  then
    echo "  server was stopped before the update and stays stopped"
  else
    echo "  no restart needed"
  fi
}

ul_verify() {
  local OK=0 N F STATE
  for F in "${FILES[@]}"
  do
    if ! cmp -s "$DIR/$F" "$WORK/$F"
    then
      echo "  FAIL $DIR/$F does not match the target version"
      OK=1
    fi
  done
  for F in /usr/local/lib/gameserver/common.sh /usr/local/lib/gameserver/shell-init.sh /usr/local/lib/gameserver/update-lxc.sh
  do
    if ! bash -n "$F" 2>/dev/null
    then
      echo "  FAIL $F missing or has a syntax error"
      OK=1
    fi
  done
  for N in $(gs_cmd_list)
  do
    [ -x "/usr/local/bin/$N" ] || { echo "  FAIL command $N missing"; OK=1; }
  done
  for F in passwords.env .env
  do
    [ -f "$DIR/$F" ] && echo "  ok   $DIR/$F kept ($(stat -c '%a %U' "$DIR/$F"))"
  done
  # Speldata: varje fil från backupen finns fortfarande
  if [ -f "$BK/gamedata.files" ]
  then
    local GONE
    GONE=$( (cd "$DIR" && while IFS= read -r F; do [ -e "$F" ] || [ -L "$F" ] || echo "$F"; done < "$BK/gamedata.files") | head -n 5)
    if [ -n "$GONE" ]
    then
      echo "  FAIL game data files are missing after the update:"
      echo "$GONE" | sed 's/^/       /'
      OK=1
    else
      echo "  ok   all $(wc -l < "$BK/gamedata.files") game data files are still there"
    fi
  fi
  if [ "$RUNNING" = 1 ]
  then
    for _ in $(seq 1 24)
    do
      STATE=$(docker inspect -f '{{.State.Status}} {{.RestartCount}}' "$CONTAINER" 2>/dev/null)
      [ "${STATE%% *}" = running ] && break
      sleep 5
    done
    if [ "${STATE%% *}" = running ]
    then
      echo "  ok   container $CONTAINER is running (restarts: ${STATE#* })"
    else
      echo "  FAIL container $CONTAINER is not running ($STATE)"
      OK=1
    fi
    if [ "$COMPOSE_CHANGED" = 1 ]
    then
      echo "  last log lines:"
      (cd "$DIR" && docker compose logs --tail 15 2>&1) | sed 's/^/       /'
      if (cd "$DIR" && docker compose logs --since 5m 2>&1) | grep -ciE 'fatal|panic|segmentation fault' > /dev/null
      then
        echo "  WARN the log contains fatal errors (see above)"
      fi
    fi
  fi
  if [ -z "$(GS_NO_BANNER=1 bash -c true 2>&1; GS_NO_BANNER=1 bash -lc true 2>&1)" ]
  then
    echo "  ok   non-interactive shells stay silent"
  else
    echo "  WARN a non-interactive shell prints output; run gameserver-check"
  fi
  return "$OK"
}

# Återställer konfiguration och programfiler från en backup (inte speldata)
ul_restore() {
  local B=$1
  [ -f "$B/config.tar.gz" ] || { echo "  $B/config.tar.gz not found"; return 1; }
  (cd "$B" && sha256sum --quiet -c SHA256SUMS) || { echo "  checksum mismatch in $B"; return 1; }
  echo "  + tar -C / -xpzf $B/config.tar.gz"
  tar -C / --numeric-owner -xpzf "$B/config.tar.gz" || return 1
  if [ -f "$B/app-files.before" ]
  then
    local F
    while IFS= read -r F
    do
      if ! grep -qxF "$F" "$B/app-files.before"
      then
        echo "  + rm -f $F   (created by the failed update)"
        rm -f -- "$F"
      fi
    done < <(ul_app_files)
  fi
  systemctl daemon-reload > /dev/null 2>&1 || true
  return 0
}

ul_rollback() {
  local B=${1:-}
  if [ -z "$B" ]
  then
    B=$(cat "$STATE_DIR/last-update-backup" 2>/dev/null)
  fi
  if [ -z "$B" ] || [ ! -d "$B" ]
  then
    echo "No backup given and none recorded. Backups: ls $BACKUP_ROOT"
    return 1
  fi
  echo "Backup: $B"
  cat "$B/INFO" 2>/dev/null | sed 's/^/  /'
  echo "Restores the commands, compose file and configuration (passwords.env, .env, settings)"
  echo "as they were before that update. Game data is not touched."
  if [ "$ASSUME_YES" = 0 ]
  then
    local A
    read -r -p "Restore? [y/N]: " A
    case "$A" in y|Y|yes|j|J|ja) ;; *) echo "Cancelled."; return 2 ;; esac
  fi
  ul_restore "$B" || { echo "Restore failed."; return 4; }
  local BEFORE
  BEFORE=$(sed -n 's/^repo_before=//p' "$B/INFO")
  if [ -n "$BEFORE" ] && [ -d "$REPO_DIR/.git" ] && [ -z "$(git -C "$REPO_DIR" status --porcelain)" ]
  then
    git -C "$REPO_DIR" checkout -q -B "$REPO_BRANCH" "$BEFORE" && echo "  repository clone back at ${BEFORE:0:7}"
  fi
  if [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null)" = true ]
  then
    (cd "$DIR" && docker compose up -d)
  fi
  echo "Done. Game data was not changed. To restore the game data from this backup as well:"
  echo "  stop"
  echo "  tar -C $DIR -tzf $B/gamedata.tar.gz | head        # look first"
  echo "  tar -C $DIR --numeric-owner -xpzf $B/gamedata.tar.gz   # overwrites files with the backup"
  echo "  start"
  return 0
}

main "$@"
exit $?
GS_EOF_UPDATE
chmod +x "$LIB_DIR/.update-lxc.sh.new"
mv -f "$LIB_DIR/.update-lxc.sh.new" "$LIB_DIR/update-lxc.sh"

# systemd-timer för auto-update (slås på/av av kommandot gameserver-auto-update)
cat > /etc/systemd/system/gameserver-autoupdate.service <<'UNITEOF'
[Unit]
Description=Game server auto-update check
After=network-online.target docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/gameserver-auto-update run
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

mk gameserver-start gs_start
mk gameserver-stop gs_stop
mk gameserver-restart gs_restart
mk gameserver-status gs_status
mk gameserver-serverlog gs_serverlog
mk gameserver-logs gs_logs
mk gameserver-update gs_update
mk gameserver-versions gs_versions
mk gameserver-backup gs_backup
mk gameserver-password 'gs_secrets "Did you save? Now run: gameserver-restart"'
mk gameserver-auto-update 'gs_autoupdate "$@"'
mk gameserver-check 'gs_check "$@"'
mk gameserver-help 'gs_help "$@"'
printf '#!/bin/bash\nexec bash %s/update-lxc.sh "$@"\n' "$LIB_DIR" > "$BIN/.gameserver-update-lxc.new"
chmod 755 "$BIN/.gameserver-update-lxc.new"
mv -f "$BIN/.gameserver-update-lxc.new" "$BIN/gameserver-update-lxc"

# Äldre kommandonamn utan prefix (start, update, server-help, ...). De skuggade andra verktygs
# kommandon, t.ex. /usr/bin/update från community-scripts. Bara våra egna stubbar tas bort.
for N in start stop restart status serverlog logs update update-game versions backup password passwords lösenord auto-update update-lxc server-check server-help
do
  F="$BIN/$N"
  [ -e "$F" ] || continue
  if grep -qE '^(\. /usr/local/lib/gameserver/common\.sh|exec bash /usr/local/lib/gameserver/update-lxc\.sh "\$@")$' "$F" && [ "$(wc -l < "$F")" -le 4 ]
  then
    rm -f -- "$F"
    echo "  tog bort det gamla kommandot $N (heter nu gameserver-...)"
  else
    echo "  Varning: $F är inte ett av våra kommandon; lämnas orört."
  fi
done

# Standard: auto-update på, uppdatera bara när servern har varit tom i 10 minuter.
# En befintlig inställning behålls.
if [ ! -f /etc/gameserver-autoupdate.conf ]
then
  cat > /etc/gameserver-autoupdate.conf <<'AUEOF'
# Auto-update settings. Change them with: gameserver-auto-update
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

# Var gameserver-update-lxc hämtar uppdateringar (befintlig fil behålls)
if [ ! -f /etc/gameserver-repo.conf ]
then
  cat > /etc/gameserver-repo.conf <<'REPOEOF'
# Used by gameserver-update-lxc. Only change these if you run your own fork.
REPO_URL=https://github.com/klangche/LXC-gameserver.git
REPO_BRANCH=main
REPO_DIR=/opt/lxc-gameserver
BACKUP_ROOT=/var/backups/gameserver
REPOEOF
fi

# ---------------------------------------------------------------- startfiler
# Ändrar bara exakt kända rader, sparar en kopia först och kontrollerar att filen
# fortfarande är giltig bash. Annat lämnas orört och visas av gameserver-check.

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
  echo "  Varning: ändringen av $1 skulle ge ogiltig bash; filen lämnas orörd (kör gameserver-check)."
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
    echo "  Varning: /etc/bash.bashrc har ett ändrat GAMESERVER_COMMANDS-block; lämnas orört (kör gameserver-check)."
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
    echo "  Varning: CUSTOM_CMDS-blocket i /etc/bash.bashrc har inget tydligt slut; lämnas orört (kör gameserver-check)."
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
    echo "  Varning: /etc/bash.bashrc har '$HOOK_BEGIN' utan slutmarkör; lämnas orört (kör gameserver-check)."
  fi
else
  printf '\n%s\n' "$HOOK" >> /etc/bash.bashrc
fi

# 5) Inloggningsskal som inte läser /etc/bash.bashrc (spärren i shell-init.sh hindrar dubbel lista)
cat > /etc/profile.d/zz-gameserver.sh <<INITEOF
# Shows the server commands in interactive login shells. Managed by install-server-commands.sh.
[ -n "\${BASH_VERSION:-}" ] && [ -r $LIB_DIR/shell-init.sh ] && . $LIB_DIR/shell-init.sh
INITEOF

# Kontrollsummor för de genererade filerna (gameserver-update-lxc ser då om någon ändrats för hand)
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
echo "Klart. Öppna ett nytt skal (skriv: bash) eller kör: gameserver-help. Kontroll: gameserver-check"

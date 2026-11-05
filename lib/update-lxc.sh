#!/bin/bash
# shellcheck disable=SC1090
# update-lxc: updates this LXC's server commands and game compose file from the Git repository.
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
# Usage: update-lxc [--dry-run] [--force] [--saves-only] [--allow-volume-change] [--yes]
#        update-lxc --rollback [BACKUP_DIR]
#        update-lxc --help
#
# The whole script is one function (main) so that it can safely replace its own installed copy.

main() {
  set -o pipefail
  umask 022

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
      *) echo "update-lxc: unknown option: $1 (see update-lxc --help)" >&2; return 1 ;;
    esac
    shift
  done

  if [ "$(id -u)" -ne 0 ]
  then
    echo "update-lxc: run as root." >&2
    return 1
  fi

  # All output also goes to the log, with the exit code at the end
  mkdir -p "$(dirname "$LOG")" "$STATE_DIR"
  exec > >(tee -a "$LOG") 2>&1
  echo
  echo "===== update-lxc $(date '+%Y-%m-%d %H:%M:%S') ($*) ====="

  exec 8> "$LOCK"
  if ! flock -n 8
  then
    echo "update-lxc is already running."
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
    echo "  MODE=$MODE: update-lxc only supports MODE=docker so far. Nothing was changed."
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
    echo "  deployed: unknown (first update-lxc on this LXC)"
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
    echo "  The target version does not contain update-lxc (older than this one). Refusing to downgrade."
    return 2
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
      echo "  $F: differs and was not deployed by update-lxc (local change or older version)."
      echo "      --force: it will be replaced; the current file is kept as $DIR/$F.local-<time>"
      diff -u "$DIR/$F" "$WORK/$F" | sed 's/^/      /' | head -n 80
    else
      BLOCKED=1
      echo "  $F: differs and was not deployed by update-lxc (local change or older version):"
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
        echo "  then run: update-lxc --allow-volume-change"
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
    echo "  passwords.env lacks:$MISSING_KEYS -> add them with 'password' after the update (not done automatically)"
  fi

  local REV_CHANGED=0
  [ "$CUR" != "$TARGET" ] && REV_CHANGED=1
  [ "$(cat "$STATE_DIR/deployed.rev" 2>/dev/null | cut -d' ' -f1)" != "$TARGET" ] && REV_CHANGED=1

  if [ "$BLOCKED" = 1 ]
  then
    echo
    echo "Stopped: the differences above need your decision. Nothing was changed."
    echo "  Keep your version:   leave it; or copy your change into the repository first."
    echo "  Take the repository: update-lxc --force   (your files are kept as *.local-<time>)"
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
    echo "ROLLBACK FAILED. Restore by hand: update-lxc --rollback $BK"
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
    echo "ROLLBACK FAILED. Restore by hand: update-lxc --rollback $BK"
    return 4
  fi
  rm -f "$STATE_DIR/update.inprogress"

  # ------------------------------------------------------------ 13. report
  ul_step "13. Result"
  echo "  Updated to $(git -C "$REPO_DIR" log -1 --format='%h %s' "$TARGET")"
  echo "  Backup: $BK   (undo: update-lxc --rollback $BK)"
  [ -n "$MISSING_KEYS" ] && echo "  To do: add$MISSING_KEYS to passwords.env with 'password', then 'restart'"
  echo "  Log: $LOG"
  return 0
}

ul_usage() {
  cat <<'EOF'
update-lxc - update the server commands of this LXC from the Git repository; game data is kept.

  update-lxc                 show the plan, ask, back up, update, verify
  update-lxc --dry-run       only show what would change (also: -n)
  update-lxc --yes           do not ask before applying (for scripts)
  update-lxc --force         replace files that differ from the repository; your versions
                             are kept next to them as <file>.local-<time>
  update-lxc --saves-only    back up only the savegame instead of all game data folders
                             (for big games when the disk is too small for a full backup)
  update-lxc --allow-volume-change
                             continue although the compose file moves the game data
  update-lxc --rollback [DIR]
                             restore commands and configuration from a backup made by
                             update-lxc (default: the last one). Game data is NOT restored
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
  for D in $(gs_cmd_list)
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
      echo "  Run 'stop' first and then update-lxc again, or use --saves-only." >&2
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
  for N in $(gs_cmd_list)
  do
    [ -e "/usr/local/bin/$N" ] && echo "/usr/local/bin/$N"
  done
  for N in /etc/profile.d/zz-gameserver.sh /etc/systemd/system/gameserver-autoupdate.service /etc/systemd/system/gameserver-autoupdate.timer
  do
    [ -e "$N" ] && echo "$N"
  done
}

gs_cmd_list() {
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
    echo "  WARN a non-interactive shell prints output; run server-check"
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

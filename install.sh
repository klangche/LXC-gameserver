#!/usr/bin/env bash
# LXC-gameserver installer. Run on the Proxmox host shell (same line for every game):
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/klangche/LXC-gameserver/main/install.sh)"
# Asks for the game, runs the community-scripts Docker helper with the game's settings,
# then installs the game server, passwords and management commands inside the LXC.
# Optional: var_game, var_cpu, var_ram, var_disk, var_os, var_ctid, var_servername, var_version, GS_RAW
set -euo pipefail

GS_RAW="${GS_RAW:-https://raw.githubusercontent.com/klangche/LXC-gameserver/main}"
GS_API="${GS_API:-https://api.github.com/repos/klangche/LXC-gameserver/contents/games}"
DOCKER_HELPER="${DOCKER_HELPER:-https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/docker.sh}"

die() { echo "ERROR: $*" >&2; exit 1; }
command -v pct > /dev/null 2>&1 || die "Run this on a Proxmox VE host."
[ "$(id -u)" -eq 0 ] || die "Run as root."

# ---- 1. Game ----
GAMES=()
while IFS= read -r g
do
  [ -n "$g" ] && GAMES+=("$g")
done < <(curl -fsSL "$GS_API" 2> /dev/null | grep -oE '"name": *"[a-z0-9_-]+"' | sed -E 's/.*"([^"]+)"$/\1/' | sort)
[ "${#GAMES[@]}" -gt 0 ] || GAMES=(csgo enshrouded minecraft rust valheim windrose)

CHOICE="${var_game:-}"
if [ -z "$CHOICE" ]
then
  echo "=== Available games ==="
  i=1
  for g in "${GAMES[@]}"
  do
    printf '  %2d) %s\n' "$i" "$g"; i=$((i + 1))
  done
  echo "Type a number, or start typing a name to filter the list."
  FILTER=""
  while [ -z "$CHOICE" ]
  do
    read -r -p "Game${FILTER:+ (filter: $FILTER)}: " IN
    if [[ "$IN" =~ ^[0-9]+$ ]] && [ "$IN" -ge 1 ] && [ "$IN" -le "${#GAMES[@]}" ]
    then
      CHOICE="${GAMES[$((IN - 1))]}"; break
    fi
    IN="$(echo "$IN" | tr '[:upper:]' '[:lower:]')"
    MATCHES=()
    for g in "${GAMES[@]}"
    do
      [ "$g" = "$IN" ] && { MATCHES=("$g"); break; }
      [[ "$g" == *"$IN"* ]] && MATCHES+=("$g")
    done
    if [ "${#MATCHES[@]}" -eq 1 ]
    then
      CHOICE="${MATCHES[0]}"
    elif [ "${#MATCHES[@]}" -eq 0 ]
    then
      echo "  No game matches '$IN'."; FILTER=""
    else
      echo "  Matches: ${MATCHES[*]}"; FILTER="$IN"
    fi
  done
fi
[[ "$CHOICE" =~ ^[a-z0-9_-]+$ ]] || die "Invalid game '$CHOICE'."

CONF="$(curl -fsSL "$GS_RAW/games/$CHOICE/game.conf")" || die "No game.conf for '$CHOICE'."
eval "$CONF"
echo "=== $TITLE gameserver ==="

# ---- 2. Servername ----
slug() { echo "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g'; }
SERVERNAME="${var_servername:-}"
if [ -z "$SERVERNAME" ]
then
  if [ "$SERVERNAME_SKIPPABLE" = "yes" ]
  then
    read -r -p "Servername (empty = skip, LXC name becomes gameserver-$GAME): " SERVERNAME
  else
    while [ -z "$(slug "$SERVERNAME")" ]
    do
      read -r -p "Servername (required for $TITLE, LXC name becomes gameserver-$GAME-<servername>): " SERVERNAME
    done
  fi
fi
SLUG="$(slug "$SERVERNAME")"
HOSTNAME_CT="gameserver-$GAME"
[ -n "$SLUG" ] && HOSTNAME_CT="$HOSTNAME_CT-$SLUG"
HOSTNAME_CT="${HOSTNAME_CT:0:63}"
echo "LXC name: $HOSTNAME_CT"

# ---- 3. Passwords (all mandatory; empty input = generated) ----
declare -A PW
for entry in "${PASSWORDS[@]}"
do
  key="${entry%%|*}"; label="${entry#*|}"
  while true
  do
    read -r -s -p "$label [$key] (empty = generate random): " val; echo
    if [ -z "$val" ]
    then
      val="$(head -c 64 /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 16)"
      echo "  generated: $val"
    fi
    if [[ "$val" =~ ^[A-Za-z0-9_.@-]{5,}$ ]]
    then
      PW[$key]="$val"; break
    fi
    echo "  Use at least 5 characters: letters, digits and _ . @ -"
  done
done

# ---- 4. Create the LXC with the community-scripts Docker helper ----
export var_cpu="${var_cpu:-$GAME_CPU}" var_ram="${var_ram:-$GAME_RAM}" var_disk="${var_disk:-$GAME_DISK}"
export var_os="${var_os:-debian}"
export var_hostname="$HOSTNAME_CT"
export var_ctid="${var_ctid:-$(pvesh get /cluster/nextid)}"
CTID="$var_ctid"
echo "Running community-scripts Docker helper (CPU $var_cpu, RAM $var_ram MB, disk ${var_disk}G, CT $CTID)..."
bash -c "$(curl -fsSL "$DOCKER_HELPER")"
pct status "$CTID" 2> /dev/null | grep -q running || die "LXC $CTID is not running; the Docker helper did not finish."

# ---- 5. Install the game server, passwords and commands ----
pct exec "$CTID" -- bash -c "command -v docker > /dev/null && command -v nano > /dev/null || { apt-get update -qq && apt-get install -y -qq curl ca-certificates nano; }; command -v docker > /dev/null || { curl -fsSL https://get.docker.com | sh && systemctl enable --now docker; }"

DIR="/opt/$GAME"
pct exec "$CTID" -- mkdir -p "$DIR"
for f in "${FILES[@]}"
do
  curl -fsSL "$GS_RAW/games/$GAME/$f" | pct exec "$CTID" -- tee "$DIR/$f" > /dev/null
done

{
  echo "# Passwords for $TITLE. Edit with the 'password' command, then run 'restart'."
  for entry in "${PASSWORDS[@]}"
  do
    key="${entry%%|*}"
    echo "$key=${PW[$key]}"
  done
} | pct exec "$CTID" -- tee "$DIR/passwords.env" > /dev/null
pct exec "$CTID" -- chmod 600 "$DIR/passwords.env"

WORLD="${SLUG:-$GAME}"
printf 'SERVER_NAME=%s\nWORLD_NAME=%s\n' "$HOSTNAME_CT" "$WORLD" | pct exec "$CTID" -- tee "$DIR/.env" > /dev/null

pct exec "$CTID" -- bash "$DIR/install-server-commands.sh" "$GAME"
pct exec "$CTID" -- bash -c ". /usr/local/lib/gameserver/common.sh && gs_start"

IP="$(pct exec "$CTID" -- hostname -I 2> /dev/null | awk '{print $1}')"
echo
echo "Done. $TITLE server '$HOSTNAME_CT' (CT $CTID) is starting at ${IP:-unknown}."
echo "Enter it with: pct enter $CTID   (commands: server-help, password, serverlog, ...)"

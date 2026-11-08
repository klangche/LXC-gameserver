#!/usr/bin/env bash
# LXC-gameserver installer. Run on the Proxmox host shell (same line for every game):
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/klangche/LXC-gameserver/main/install.sh)"
# Asks for the game, creates the LXC itself with pct (no community-scripts helper), installs
# Docker in it (lib/provision-lxc.sh), then the game server, passwords and gameserver-* commands.
# Optional: var_game, var_servername, var_mcp (yes/no), var_cpu, var_ram, var_disk, var_os (debian|ubuntu),
#   var_version, var_ctid, var_storage, var_template_storage, var_bridge, var_ip (dhcp or CIDR),
#   var_gw, var_yes (yes = do not ask before creating), GS_RAW
set -euo pipefail

GS_RAW="${GS_RAW:-https://raw.githubusercontent.com/klangche/LXC-gameserver/main}"
GS_API="${GS_API:-https://api.github.com/repos/klangche/LXC-gameserver/contents/games}"

die() { echo "ERROR: $*" >&2; exit 1; }
command -v pct > /dev/null 2>&1 || die "Run this on a Proxmox VE host."
[ "$(id -u)" -eq 0 ] || die "Run as root."

# ---- 1. Game ----
GAMES=()
while IFS= read -r g
do
  [ -n "$g" ] && GAMES+=("$g")
done < <(curl -fsSL "$GS_API" 2> /dev/null | grep -oE '"name": *"[a-z0-9_-]+"' | sed -E 's/.*"([^"]+)"$/\1/' | sort)
[ "${#GAMES[@]}" -gt 0 ] || GAMES=(cs2 enshrouded minecraft rust valheim windrose)

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
SERVER_NAMES=()
while [ -z "$(slug "$SERVERNAME")" ]
do
  if [ -z "$SERVERNAME" ]
  then
    read -r -p "Servername (enter your own, or leave empty for a random server name): " SERVERNAME
    if [ -z "$SERVERNAME" ]
    then
      if [ "${#SERVER_NAMES[@]}" -eq 0 ]
      then
        mapfile -t SERVER_NAMES < <(curl -fsSL "$GS_RAW/server-names.txt" | grep -vE '^[[:space:]]*(#|$)')
        [ "${#SERVER_NAMES[@]}" -gt 0 ] || die "No random server names found in $GS_RAW/server-names.txt."
      fi
      SERVERNAME="${SERVER_NAMES[$((RANDOM % ${#SERVER_NAMES[@]}))]}"
      echo "  Random servername: $SERVERNAME"
    fi
  else
    read -r -p "Servername must contain letters or numbers; try again: " SERVERNAME
  fi
done
SLUG="$(slug "$SERVERNAME")"
HOSTNAME_CT="gameserver-$GAME-$SLUG"
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
      val="$(head -c 512 /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 16)"
      echo "  generated: $val"
    fi
    if [[ "$val" =~ ^[A-Za-z0-9_.@-]{5,}$ ]]
    then
      PW[$key]="$val"; break
    fi
    echo "  Use at least 5 characters: letters, digits and _ . @ -"
  done
done

# ---- 3b. Optional MCP server ----
MCP="${var_mcp:-}"
if [ -z "$MCP" ]
then
  read -r -p "Add an MCP server container (for opencode or similar on the same network, no authentication)? [y/N]: " MCP
fi
case "$MCP" in y | Y | yes | YES | 1 | true) MCP=yes ;; *) MCP=no ;; esac

# ---- 4. Create the LXC (own pct commands; no community-scripts) ----
CPU="${var_cpu:-$GAME_CPU}"
RAM="${var_ram:-$GAME_RAM}"
DISK="${var_disk:-$GAME_DISK}"
OS="${var_os:-debian}"
case "$OS" in
  debian) OS_VERSION="${var_version:-12}" ;;
  ubuntu) OS_VERSION="${var_version:-24.04}" ;;
  *) die "var_os must be debian or ubuntu." ;;
esac
BRIDGE="${var_bridge:-vmbr0}"
IP="${var_ip:-dhcp}"
CTID="${var_ctid:-$(pvesh get /cluster/nextid)}"

# first_storage CONTENT PREFERRED: an active storage that holds CONTENT, PREFERRED if it has it
first_storage() {
  local list
  list=$(pvesm status -content "$1" 2> /dev/null | awk 'NR > 1 && $3 == "active" {print $1}' || true)
  if echo "$list" | grep -qx "$2"
  then
    echo "$2"
  else
    echo "$list" | head -n 1
  fi
}
STORAGE="${var_storage:-$(first_storage rootdir local-lvm)}"
TEMPLATE_STORAGE="${var_template_storage:-$(first_storage vztmpl local)}"
[ -n "$STORAGE" ] || die "No storage for containers found (set var_storage)."
[ -n "$TEMPLATE_STORAGE" ] || die "No storage for templates found (set var_template_storage)."
pct status "$CTID" > /dev/null 2>&1 && die "CT $CTID already exists (set var_ctid)."
if pct list 2> /dev/null | awk 'NR > 1 {print $NF}' | grep -qx "$HOSTNAME_CT"
then
  die "An LXC named $HOSTNAME_CT already exists."
fi

echo "Looking for the $OS $OS_VERSION template..."
pveam update > /dev/null 2>&1 || echo "  (pveam update failed; using the template list as it is)"
TEMPLATE="$(pveam available --section system | awk '{print $2}' | grep -E "^${OS}-${OS_VERSION}(\.[0-9]+)?-standard_" | sort -V | tail -n 1 || true)"
[ -n "$TEMPLATE" ] || die "No $OS $OS_VERSION standard template in 'pveam available'."
if ! pveam list "$TEMPLATE_STORAGE" | grep -q "$TEMPLATE"
then
  pveam download "$TEMPLATE_STORAGE" "$TEMPLATE"
fi

NET="name=eth0,bridge=$BRIDGE,ip=$IP"
[ -n "${var_gw:-}" ] && NET="$NET,gw=$var_gw"
echo
echo "=== LXC to create ==="
echo "  CT $CTID  $HOSTNAME_CT  ($OS $OS_VERSION, unprivileged, nesting+keyctl for Docker)"
echo "  CPU $CPU, RAM $RAM MB, disk ${DISK} GB on $STORAGE, network $NET"
if [ "${var_yes:-}" != yes ]
then
  read -r -p "Create it? [Y/n]: " OK
  case "$OK" in n | N | no | NO) die "Cancelled; nothing was created." ;; esac
fi

pct create "$CTID" "$TEMPLATE_STORAGE:vztmpl/$TEMPLATE" \
  --hostname "$HOSTNAME_CT" \
  --cores "$CPU" --memory "$RAM" --swap 512 \
  --rootfs "$STORAGE:$DISK" \
  --net0 "$NET" \
  --unprivileged 1 --features nesting=1,keyctl=1 \
  --onboot 1 --timezone host \
  --tags "gameserver;$GAME" \
  --description "$TITLE game server (LXC-gameserver). Commands inside: gameserver-help"
pct start "$CTID"
for _ in $(seq 1 30)
do
  pct status "$CTID" | grep -q running && break
  sleep 1
done
pct status "$CTID" | grep -q running || die "LXC $CTID did not start."

# ---- 5. Docker, the game server, passwords and commands ----
echo "Installing Docker in the LXC..."
curl -fsSL "$GS_RAW/lib/provision-lxc.sh" | pct exec "$CTID" -- bash -s || die "Setting up the LXC failed (see above). CT $CTID is left as it is."

DIR="/opt/$GAME"
pct exec "$CTID" -- mkdir -p "$DIR"
for f in "${FILES[@]}"
do
  curl -fsSL "$GS_RAW/games/$GAME/$f" | pct exec "$CTID" -- tee "$DIR/$f" > /dev/null
done

{
  echo "# Passwords for $TITLE. Edit with gameserver-password, then run gameserver-restart."
  for entry in "${PASSWORDS[@]}"
  do
    key="${entry%%|*}"
    echo "$key=${PW[$key]}"
  done
} | pct exec "$CTID" -- tee "$DIR/passwords.env" > /dev/null
pct exec "$CTID" -- chmod 600 "$DIR/passwords.env"

WORLD="${SLUG:-$GAME}"
printf 'SERVER_NAME=%s\nWORLD_NAME=%s\n' "$HOSTNAME_CT" "$WORLD" | pct exec "$CTID" -- tee "$DIR/.env" > /dev/null

pct exec "$CTID" -- bash "$DIR/install-server-commands.sh" "$GAME" --record-deployed
pct exec "$CTID" -- bash -c ". /usr/local/lib/gameserver/common.sh && gs_start"

if [ "$MCP" = "yes" ]
then
  pct exec "$CTID" -- mkdir -p /opt/mcp
  curl -fsSL "$GS_RAW/mcp/docker-compose.yml" | pct exec "$CTID" -- tee /opt/mcp/docker-compose.yml > /dev/null
  pct exec "$CTID" -- docker compose -f /opt/mcp/docker-compose.yml up -d
fi

CT_IP="$(pct exec "$CTID" -- hostname -I 2> /dev/null | awk '{print $1}')"
echo
echo "Done. $TITLE server '$HOSTNAME_CT' (CT $CTID) is starting at ${CT_IP:-unknown}."
[ "$MCP" = "yes" ] && echo "MCP server (streamable HTTP, filesystem access to /opt) at http://${CT_IP:-unknown}:8000/mcp - LAN only, no authentication."
echo "Enter it with: pct enter $CTID   (commands: gameserver-help, gameserver-password, gameserver-serverlog, ...)"

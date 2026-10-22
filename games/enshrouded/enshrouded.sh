#!/usr/bin/env bash
# Enshrouded gameserver LXC for Proxmox VE. Run on the Proxmox host shell:
#   var_cpu="4" var_ram="8192" var_disk="30" var_os='debian' bash -c "$(curl -fsSL https://raw.githubusercontent.com/klangche/LXC-gameserver/main/games/enshrouded/enshrouded.sh)"
# Optional: var_storage, var_template_storage, var_bridge, var_version, var_ctid, var_servername, GS_RAW
set -euo pipefail

GAME="enshrouded"
TITLE="Enshrouded"
SERVERNAME_SKIPPABLE="yes"
# KEY|Label for every mandatory password of this game (written to passwords.env)
PASSWORDS=("SERVER_ROLE_0_PASSWORD|Admin password" "SERVER_ROLE_1_PASSWORD|Friend password" "SERVER_ROLE_2_PASSWORD|Guest password")
FILES=(docker-compose.yml passwords.env install-server-commands.sh)

GS_RAW="${GS_RAW:-https://raw.githubusercontent.com/klangche/LXC-gameserver/main}"
var_cpu="${var_cpu:-4}"
var_ram="${var_ram:-8192}"
var_disk="${var_disk:-30}"
var_os="${var_os:-debian}"
var_storage="${var_storage:-local-lvm}"
var_template_storage="${var_template_storage:-local}"
var_bridge="${var_bridge:-vmbr0}"

die() { echo "ERROR: $*" >&2; exit 1; }

command -v pct > /dev/null 2>&1 || die "Run this on a Proxmox VE host."
[ "$(id -u)" -eq 0 ] || die "Run as root."
case "$var_os" in debian|ubuntu) ;; *) die "var_os must be debian or ubuntu." ;; esac

# Question 1 was "which game": it is answered by the script you pasted ($GAME).
echo "=== $TITLE gameserver ==="

# Question 2: servername
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

# Question 3: passwords (all mandatory; empty input = generated)
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

CTID="${var_ctid:-$(pvesh get /cluster/nextid)}"

# Template
pveam update > /dev/null 2>&1 || true
TEMPLATE="$(pveam available --section system | awk '{print $2}' | grep -E "^${var_os}-${var_version:-[0-9]+}.*standard" | sort -V | tail -n1)"
[ -n "$TEMPLATE" ] || die "No $var_os template found."
pveam list "$var_template_storage" | grep -q "$TEMPLATE" || pveam download "$var_template_storage" "$TEMPLATE"

echo "Creating LXC $CTID ($var_cpu cpu, $var_ram MB ram, ${var_disk}G disk)..."
pct create "$CTID" "$var_template_storage:vztmpl/$TEMPLATE" \
  --hostname "$HOSTNAME_CT" --cores "$var_cpu" --memory "$var_ram" --swap 512 \
  --rootfs "$var_storage:$var_disk" --net0 "name=eth0,bridge=$var_bridge,ip=dhcp" \
  --features nesting=1,keyctl=1 --unprivileged 1 --onboot 1 --tags gameserver
pct start "$CTID"

echo "Waiting for network..."
for _ in $(seq 1 30)
do
  pct exec "$CTID" -- getent hosts deb.debian.org > /dev/null 2>&1 && break
  pct exec "$CTID" -- getent hosts archive.ubuntu.com > /dev/null 2>&1 && break
  sleep 2
done

echo "Installing Docker (always included, so you can add more containers)..."
pct exec "$CTID" -- bash -c "apt-get update -qq && apt-get install -y -qq curl ca-certificates nano && curl -fsSL https://get.docker.com | sh && systemctl enable --now docker"

DIR="/opt/$GAME"
pct exec "$CTID" -- mkdir -p "$DIR"
for f in "${FILES[@]}"
do
  curl -fsSL "$GS_RAW/games/$GAME/$f" | pct exec "$CTID" -- tee "$DIR/$f" > /dev/null
done

# passwords.env: replace the template with the chosen passwords
{
  echo "# Passwords for $TITLE. Edit with the 'password' command, then run 'restart'."
  for entry in "${PASSWORDS[@]}"
  do
    key="${entry%%|*}"
    echo "$key=${PW[$key]}"
  done
} | pct exec "$CTID" -- tee "$DIR/passwords.env" > /dev/null
pct exec "$CTID" -- chmod 600 "$DIR/passwords.env"

# .env: in-game name (= LXC name) and world name, read by docker compose
WORLD="${SLUG:-$GAME}"
printf 'SERVER_NAME=%s\nWORLD_NAME=%s\n' "$HOSTNAME_CT" "$WORLD" | pct exec "$CTID" -- tee "$DIR/.env" > /dev/null

pct exec "$CTID" -- bash "$DIR/install-server-commands.sh" "$GAME"
pct exec "$CTID" -- bash -c ". /usr/local/lib/gameserver/common.sh && gs_start"

IP="$(pct exec "$CTID" -- hostname -I 2>/dev/null | awk '{print $1}')"
echo
echo "Done. $TITLE server '$HOSTNAME_CT' (CT $CTID) is starting at ${IP:-unknown}."
echo "Enter it with: pct enter $CTID   (commands: server-help, password, serverlog, ...)"

#!/usr/bin/env bash
# Game picker for Proxmox VE. Run on the Proxmox host shell:
#   var_cpu="4" var_ram="8192" var_disk="30" var_os='debian' bash -c "$(curl -fsSL https://raw.githubusercontent.com/klangche/LXC-gameserver/main/install.sh)"
# Optional: var_game (skip the question), GS_RAW, plus every variable the game scripts accept.
set -euo pipefail

GS_RAW="${GS_RAW:-https://raw.githubusercontent.com/klangche/LXC-gameserver/main}"
GS_API="${GS_API:-https://api.github.com/repos/klangche/LXC-gameserver/contents/games}"

# Game list from the repo (new games show up automatically); fallback list if offline
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

[[ "$CHOICE" =~ ^[a-z0-9_-]+$ ]] || { echo "ERROR: invalid game '$CHOICE'." >&2; exit 1; }
echo "Selected: $CHOICE"
SCRIPT="$(curl -fsSL "$GS_RAW/games/$CHOICE/$CHOICE.sh")" || { echo "ERROR: no script for '$CHOICE'." >&2; exit 1; }
export GS_RAW
exec bash -c "$SCRIPT"

# shellcheck shell=bash
# Shared helpers for the tests (sourced inside the sandbox).
REPO=${REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
FAILS=0
check() {  # check NAME EXPECTED ACTUAL
  if [ "$2" = "$3" ]
  then
    echo "ok   $1"
  else
    echo "FAIL $1: expected [$2], got [$3]"
    FAILS=$((FAILS + 1))
  fi
}
done_tests() {
  echo
  [ "$FAILS" = 0 ] && echo "all checks passed" || echo "$FAILS check(s) FAILED"
  exit "$FAILS"
}
# Ett äldre, manuellt underhållet Enshrouded-LXC (före repot + första versionen ur repot)
legacy_setup() {
  install -m 755 "$REPO/tests/fake-docker" /usr/local/bin/docker
  mkdir -p /opt/enshrouded/game/savegame /opt/enshrouded/game/server
  echo world1 > /opt/enshrouded/game/savegame/3ad85aea
  echo world1-backup > /opt/enshrouded/game/savegame/3ad85aea-1
  ln -sfn 3ad85aea /opt/enshrouded/game/savegame/latest
  echo binary > /opt/enshrouded/game/server/enshrouded_server.exe
  cp "$REPO/tests/fixtures/legacy-docker-compose.yml" /opt/enshrouded/docker-compose.yml
  cp "$REPO/tests/fixtures/legacy-install-server-commands.sh" /opt/enshrouded/install-server-commands.sh
  printf 'SERVER_ROLE_0_PASSWORD=abcde1\nSERVER_ROLE_1_PASSWORD=abcde2\nSERVER_ROLE_2_PASSWORD=abcde3\n' > /opt/enshrouded/passwords.env
  chmod 600 /opt/enshrouded/passwords.env
  printf 'SERVER_NAME=gameserver-enshrouded-test\nWORLD_NAME=test\n' > /opt/enshrouded/.env
  bash /opt/enshrouded/install-server-commands.sh enshrouded > /dev/null 2>&1
  printf '\n# CUSTOM_CMDS - my server commands\nif [ -n "$PS1" ]; then\n  echo "Commands: start stop update"\nfi\n' >> /etc/bash.bashrc
  printf "alias update='cd /opt/enshrouded && docker compose pull && docker compose up -d'\nif [ -n \"\$PS1\" ]; then\n  enshrouded-help\nfi\n" >> /root/.bashrc
  sed -i 's/SERVER_SLOTS=16/SERVER_SLOTS=8/' /opt/enshrouded/docker-compose.yml
}
banners() { grep -c ' commands (' ; }
data_snapshot() {
  (cd /opt/enshrouded && find game \( -type f -o -type l \) | sort | xargs -d '\n' sha256sum
   sha256sum passwords.env .env; stat -c '%n %a %u' passwords.env .env)
}

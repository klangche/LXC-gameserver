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

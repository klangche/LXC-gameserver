# Valheim

Use the main command from the [top-level README](../../README.md) and pick `valheim` when asked (or set `var_game="valheim"`).

- LXC name: `gameserver-valheim-<servername>` (enter your own name or leave empty for a random sighthound breed)
- Ports to forward: 2456/udp 2457/udp 2458/udp
- Passwords asked on first launch (all mandatory, blank = random): SERVER_PASS
- Files: `game.conf` (name, passwords, default resources), `docker-compose.yml`, `passwords.env` (template), `install-server-commands.sh`

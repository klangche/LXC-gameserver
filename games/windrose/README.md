# Windrose

Use the main command from the [top-level README](../../README.md) and pick `windrose` when asked (or set `var_game="windrose"`).

- LXC name: `gameserver-windrose-<servername>` (enter your own name or leave empty for a random server name)
- Ports to forward: 7777/udp 7777/tcp 7778/udp
- Passwords asked on first launch (all mandatory, blank = random): SERVER_PASSWORD
- Files: `game.conf` (name, passwords, default resources), `docker-compose.yml`, `passwords.env` (template), `install-server-commands.sh`

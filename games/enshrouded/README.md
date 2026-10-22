# Enshrouded

Use the main command from the [top-level README](../../README.md) and pick `enshrouded` when asked (or set `var_game="enshrouded"`).

- LXC name: `gameserver-enshrouded` or `gameserver-enshrouded-<servername>`
- Server name can be skipped: **yes**
- Ports to forward: 15636/udp 15637/udp
- Passwords asked on first launch (all mandatory, blank = random): SERVER_ROLE_0_PASSWORD, SERVER_ROLE_1_PASSWORD, SERVER_ROLE_2_PASSWORD
- Files: `game.conf` (name, passwords, default resources), `docker-compose.yml`, `passwords.env` (template), `install-server-commands.sh`

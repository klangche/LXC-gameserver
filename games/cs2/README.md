# Counter-Strike 2

Use the main command from the [top-level README](../../README.md) and pick `cs2` when asked (or set `var_game="cs2"`).

- LXC name: `gameserver-cs2` or `gameserver-cs2-<servername>`
- Server name can be skipped: **yes**
- Ports to forward: 27015/tcp 27015/udp
- Passwords asked on first launch (all mandatory, blank = random): CS2_PW, CS2_RCONPW, SRCDS_TOKEN
- Files: `game.conf` (name, passwords, default resources), `docker-compose.yml`, `passwords.env` (template), `install-server-commands.sh`

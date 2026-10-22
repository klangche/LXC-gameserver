# Minecraft (Java)

Use the main command from the [top-level README](../../README.md) and pick `minecraft` when asked (or set `var_game="minecraft"`).

- LXC name: `gameserver-minecraft` or `gameserver-minecraft-<servername>`
- Server name can be skipped: **yes**
- Ports to forward: 25565/tcp
- Passwords asked on first launch (all mandatory, blank = random): RCON_PASSWORD
- Files: `game.conf` (name, passwords, default resources), `docker-compose.yml`, `passwords.env` (template), `install-server-commands.sh`

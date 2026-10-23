# Minecraft (Java)

Use the main command from the [top-level README](../../README.md) and pick `minecraft` when asked (or set `var_game="minecraft"`).

- LXC name: `gameserver-minecraft-<servername>` (enter your own name or leave empty for a random sighthound breed)
- Ports to forward: 25565/tcp
- Passwords asked on first launch (all mandatory, blank = random): RCON_PASSWORD
- Files: `game.conf` (name, passwords, default resources), `docker-compose.yml`, `passwords.env` (template), `install-server-commands.sh`

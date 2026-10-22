# Minecraft (Java)

Run on the Proxmox VE host shell:

```bash
var_cpu="4" var_ram="6144" var_disk="20" var_os='debian' bash -c "$(curl -fsSL https://raw.githubusercontent.com/klangche/LXC-gameserver/main/games/minecraft/minecraft.sh)"
```

- LXC name: `gameserver-minecraft` or `gameserver-minecraft-<servername>`
- Server name can be skipped: **yes**
- Ports to forward: 25565/tcp
- Passwords asked on first launch (all mandatory, blank = random): RCON_PASSWORD
- Files: `minecraft.sh` (host script), `docker-compose.yml`, `passwords.env` (template), `install-server-commands.sh`

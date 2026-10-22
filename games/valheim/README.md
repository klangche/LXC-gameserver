# Valheim

Run on the Proxmox VE host shell:

```bash
var_cpu="4" var_ram="4096" var_disk="20" var_os='debian' bash -c "$(curl -fsSL https://raw.githubusercontent.com/klangche/LXC-gameserver/main/games/valheim/valheim.sh)"
```

- LXC name: `gameserver-valheim` or `gameserver-valheim-<servername>`
- Server name can be skipped: **no**
- Ports to forward: 2456/udp 2457/udp 2458/udp
- Passwords asked on first launch (all mandatory, blank = random): SERVER_PASS
- Files: `valheim.sh` (host script), `docker-compose.yml`, `passwords.env` (template), `install-server-commands.sh`

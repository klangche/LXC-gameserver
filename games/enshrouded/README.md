# Enshrouded

Run on the Proxmox VE host shell:

```bash
var_cpu="4" var_ram="8192" var_disk="30" var_os='debian' bash -c "$(curl -fsSL https://raw.githubusercontent.com/klangche/LXC-gameserver/main/games/enshrouded/enshrouded.sh)"
```

- LXC name: `gameserver-enshrouded` or `gameserver-enshrouded-<servername>`
- Server name can be skipped: **yes**
- Ports to forward: 15636/udp 15637/udp
- Passwords asked on first launch (all mandatory, blank = random): SERVER_ROLE_0_PASSWORD, SERVER_ROLE_1_PASSWORD, SERVER_ROLE_2_PASSWORD
- Files: `enshrouded.sh` (host script), `docker-compose.yml`, `passwords.env` (template), `install-server-commands.sh`

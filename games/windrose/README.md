# Windrose

Run on the Proxmox VE host shell:

```bash
var_cpu="4" var_ram="16384" var_disk="40" var_os='debian' bash -c "$(curl -fsSL https://raw.githubusercontent.com/klangche/LXC-gameserver/main/games/windrose/windrose.sh)"
```

- LXC name: `gameserver-windrose` or `gameserver-windrose-<servername>`
- Server name can be skipped: **yes**
- Ports to forward: 7777/udp 7777/tcp 7778/udp
- Passwords asked on first launch (all mandatory, blank = random): SERVER_PASSWORD
- Files: `windrose.sh` (host script), `docker-compose.yml`, `passwords.env` (template), `install-server-commands.sh`

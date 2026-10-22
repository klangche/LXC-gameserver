# CS:GO (runs Counter-Strike 2)

Run on the Proxmox VE host shell:

```bash
var_cpu="4" var_ram="4096" var_disk="60" var_os='debian' bash -c "$(curl -fsSL https://raw.githubusercontent.com/klangche/LXC-gameserver/main/games/csgo/csgo.sh)"
```

- LXC name: `gameserver-csgo` or `gameserver-csgo-<servername>`
- Server name can be skipped: **yes**
- Ports to forward: 27015/tcp 27015/udp
- Passwords asked on first launch (all mandatory, blank = random): CS2_PW, CS2_RCONPW, SRCDS_TOKEN
- Files: `csgo.sh` (host script), `docker-compose.yml`, `passwords.env` (template), `install-server-commands.sh`

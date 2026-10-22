# Rust

Run on the Proxmox VE host shell:

```bash
var_cpu="4" var_ram="12288" var_disk="40" var_os='debian' bash -c "$(curl -fsSL https://raw.githubusercontent.com/klangche/LXC-gameserver/main/games/rust/rust.sh)"
```

- LXC name: `gameserver-rust` or `gameserver-rust-<servername>`
- Server name can be skipped: **yes**
- Ports to forward: 28015/udp 28016/tcp 28082/tcp
- Passwords asked on first launch (all mandatory, blank = random): RUST_RCON_PASSWORD
- Files: `rust.sh` (host script), `docker-compose.yml`, `passwords.env` (template), `install-server-commands.sh`

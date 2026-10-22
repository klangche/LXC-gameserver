# Rust

Use the main command from the [top-level README](../../README.md) and pick `rust` when asked (or set `var_game="rust"`).

- LXC name: `gameserver-rust` or `gameserver-rust-<servername>`
- Server name can be skipped: **yes**
- Ports to forward: 28015/udp 28016/tcp 28082/tcp
- Passwords asked on first launch (all mandatory, blank = random): RUST_RCON_PASSWORD
- Files: `game.conf` (name, passwords, default resources), `docker-compose.yml`, `passwords.env` (template), `install-server-commands.sh`

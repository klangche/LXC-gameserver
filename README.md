# LXC-gameserver

One-line Proxmox VE scripts that create a ready-to-play game server in an LXC container. Style and idea follow the [community-scripts](https://community-scripts.org/) helper scripts (`var_cpu`, `var_ram`, `var_disk`, `var_os`).

Every LXC is created by the community-scripts Docker helper, so it gets **Docker** (so you can add more containers later), a Docker-based game server, and the same set of management commands (`start`, `stop`, `restart`, `status`, `serverlog`, `logs`, `update`, `versions`, `backup`, `password`, `server-help`).

## How to use

Paste this in the **Proxmox VE host shell** (the same line for every game):

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/klangche/LXC-gameserver/main/install.sh)"
```

What happens:

1. **Game**: the shell asks which game (pick a number or type part of the name to filter).
2. **Settings**: CPU, RAM and disk are set for that game, then the community-scripts Docker helper (`ct/docker.sh`) is run with them, e.g. for Enshrouded:
   `var_cpu="4" var_ram="8192" var_disk="30" var_os='debian' bash -c "$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/docker.sh)"`
   It creates the LXC with Docker. You can still adjust its settings in its own menu.
3. **Servername**: enter a name of your choice, or leave it empty to choose a random sighthound breed.
   - LXC name is always `gameserver-<game>-<servername>`, e.g. `gameserver-valheim-friends` or `gameserver-valheim-whippet`.
   - The in-game server name is the LXC name.
4. **Passwords**: every password the game has is asked (empty = random). Change them later with `password` (opens all of them in nano), then run `restart`.
5. **Install**: the game server and the commands (`start`, `stop`, `restart`, `status`, `serverlog`, `logs`, `update`, `versions`, `backup`, `password`, `server-help`) are installed in the LXC and started.

Optional variables: `var_game` (skip the question), `var_cpu`, `var_ram`, `var_disk` (override the game's defaults), `var_os`, `var_ctid`, `var_servername`, `var_version`, and any other variable the community-scripts helper accepts.

## Optional MCP server

The installer asks whether to add an MCP server container (`var_mcp=yes|no` to skip the question). It runs next to the game in the LXC ([mcp/docker-compose.yml](mcp/docker-compose.yml)) and exposes the filesystem tools for `/opt` (game compose files, passwords, configs) over streamable HTTP at `http://<lxc-ip>:8000/mcp`. Point opencode or a similar client on the same network at it for troubleshooting and changes. There is **no authentication**: keep it on a trusted LAN and never forward port 8000.

## Games

| Game | Folder | Passwords asked | Ports |
|------|--------|-----------------|-------|
| Enshrouded | [games/enshrouded](games/enshrouded) | Admin, Friend, Guest role passwords | 15636-15637/udp |
| Valheim | [games/valheim](games/valheim) | server password (min 5 chars) | 2456-2458/udp |
| Windrose | [games/windrose](games/windrose) | server password | 7777/udp+tcp, 7778/udp |
| Minecraft (Java) | [games/minecraft](games/minecraft) | RCON password | 25565/tcp |
| Rust | [games/rust](games/rust) | RCON password | 28015/udp, 28016/tcp, 28082/tcp |
| Counter-Strike 2 | [games/cs2](games/cs2) | server password, RCON password, Steam GSLT token | 27015/tcp+udp |

Notes: Counter-Strike 2 needs a Steam [Game Server Login Token](https://steamcommunity.com/dev/managegameservers) (app 730). Game images are community-maintained; check their documentation if an environment variable changes. Forward the listed ports on your router.

## Folder layout

```
games/<game>/
  game.conf                    name, passwords, default CPU/RAM/disk
  docker-compose.yml           the game server
  passwords.env                password template (filled in on first launch)
  install-server-commands.sh   installs start/stop/status/... inside the LXC
  README.md                    game info
mcp/docker-compose.yml         optional MCP server
```

Every game folder has its own README with ports, passwords and LXC name.

## Submit a new game

Fork the repo, copy an existing folder in `games/` (e.g. `games/valheim`), adapt it, and open a pull request. [llm.txt](llm.txt) contains exact instructions, so you can also hand it to an LLM and ask it to add your game. Please add the game to the table above.

## License

Free to fork and use, MIT licensed.

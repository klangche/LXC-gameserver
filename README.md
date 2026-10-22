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
3. **Servername**: some games allow skipping it (see table).
   - LXC name is `gameserver-<game>` (skipped) or `gameserver-<game>-<servername>`, e.g. `gameserver-valheim-friends`.
   - The in-game server name is the LXC name.
4. **Passwords**: every password the game has is asked (empty = random). Change them later with `password` (opens all of them in nano), then run `restart`.
5. **Install**: the game server and the commands (`start`, `stop`, `restart`, `status`, `serverlog`, `logs`, `update`, `versions`, `backup`, `password`, `server-help`) are installed in the LXC and started.

Optional variables: `var_game` (skip the question), `var_cpu`, `var_ram`, `var_disk` (override the game's defaults), `var_os`, `var_ctid`, `var_servername`, `var_version`, and any other variable the community-scripts helper accepts.

## Games

| Game | Folder | Servername skippable | Passwords asked | Ports |
|------|--------|----------------------|-----------------|-------|
| Enshrouded | [games/enshrouded](games/enshrouded) | yes | Admin, Friend, Guest role passwords | 15636-15637/udp |
| Valheim | [games/valheim](games/valheim) | no | server password (min 5 chars) | 2456-2458/udp |
| Windrose | [games/windrose](games/windrose) | yes | server password | 7777/udp+tcp, 7778/udp |
| Minecraft (Java) | [games/minecraft](games/minecraft) | yes | RCON password | 25565/tcp |
| Rust | [games/rust](games/rust) | yes | RCON password | 28015/udp, 28016/tcp, 28082/tcp |
| CS:GO | [games/csgo](games/csgo) | yes | server password, RCON password, Steam GSLT token | 27015/tcp+udp |

Notes: CS:GO was replaced by Counter-Strike 2; the `csgo` folder runs the CS2 server image and needs a Steam [Game Server Login Token](https://steamcommunity.com/dev/managegameservers) (app 730). Game images are community-maintained; check their documentation if an environment variable changes. Forward the listed ports on your router.

## Folder layout

```
games/<game>/
  game.conf                    name, passwords, default CPU/RAM/disk
  docker-compose.yml           the game server
  passwords.env                password template (filled in on first launch)
  install-server-commands.sh   installs start/stop/status/... inside the LXC
  README.md                    game info
```

## Submit a new game

Fork the repo, copy an existing folder in `games/` (e.g. `games/valheim`), adapt it, and open a pull request. [llm.txt](llm.txt) contains exact instructions, so you can also hand it to an LLM and ask it to add your game. Please add the game to the table above.

## License

Free to fork and use, MIT licensed.

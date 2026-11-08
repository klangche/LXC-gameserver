# LXC-gameserver

One-line Proxmox VE scripts that create a ready-to-play game server in an LXC container. Style and idea follow the [community-scripts](https://community-scripts.org/) helper scripts (`var_cpu`, `var_ram`, `var_disk`, `var_os`).

Every LXC is created by the community-scripts Docker helper, so it gets **Docker** (so you can add more containers later), a Docker-based game server, and the same set of management commands. They all start with `gameserver-` (type `gameserver-` and press Tab). See [docs/commands.md](docs/commands.md).

The community-scripts helper is used exactly as it is published: this project never changes it or anything it installs in the LXC (for example its own `update` command).

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
3. **Servername**: enter a name of your choice, or leave it empty to choose a random server name. Random name candidates are listed in [`server-names.txt`](server-names.txt); add one name per line to include other breeds or animals.
   - LXC name is always `gameserver-<game>-<servername>`, e.g. `gameserver-valheim-friends` or `gameserver-valheim-whippet`.
   - The in-game server name is the LXC name.
4. **Passwords**: every password the game has is asked (empty = random). Change them later with `gameserver-password` (opens all of them in nano), then run `gameserver-restart`.
5. **Install**: the game server and the `gameserver-*` commands are installed in the LXC and started.

Optional variables: `var_game` (skip the question), `var_cpu`, `var_ram`, `var_disk` (override the game's defaults), `var_os`, `var_ctid`, `var_servername`, `var_version`, and any other variable the community-scripts helper accepts.

## Commands in the LXC

Typing `bash`, opening a terminal or logging in shows the list once (`gameserver-help`; `gameserver-help --full` adds arguments and examples). The full reference, including when the list is shown and why the names have a prefix, is in [docs/commands.md](docs/commands.md).

| Command | What it does |
|---------|--------------|
| `gameserver-status`, `gameserver-serverlog`, `gameserver-logs` | server status, live server log, live container log |
| `gameserver-start`, `gameserver-stop`, `gameserver-restart` | control the game server |
| `gameserver-update` | backup + update the game itself |
| `gameserver-versions`, `gameserver-backup` | installed vs latest version, savegame backup |
| `gameserver-password` | edit all passwords in nano, then `gameserver-restart` |
| `gameserver-auto-update [on\|off\|status\|log]` | automatic game updates (see below) |
| `gameserver-update-lxc [--dry-run]` | update these commands from this repository; game data is kept |
| `gameserver-check` | find command conflicts and startup-file problems |
| `gameserver-help [--full]` | the list |

## Auto-update

Type `gameserver-auto-update` in the LXC shell. It shows the current settings and asks:

1. **Auto-update**: ON → switch it OFF? / OFF → switch it ON?
2. **Update even if players are online**: ON → switch it OFF? / OFF → switch it ON? ON = update even while people are playing; OFF = wait until no one has been online for the minutes in question 3.
3. **Update after how many minutes with no players online?** Only asked when question 2 is OFF. When it is ON, the server updates as soon as an update is found.

Defaults on a new server: auto-update **ON**, update even if players are online **OFF**, update after **10** minutes with no players online. Re-running the install keeps your own settings.

When auto-update is on, a systemd timer (`gameserver-autoupdate.timer`) runs every minute. Every 30 minutes (`CHECK_EVERY` in `/etc/gameserver-autoupdate.conf`) it looks for a newer Docker image, a newer Steam build or a newer Minecraft release. When one is found it runs `gameserver-update` (backup first), right away or once the server has been empty for the chosen number of minutes. The player count comes from a Steam server query (A2S) on the game's query port, or from `rcon-cli list` for Minecraft. Servers you stopped yourself are left alone.

Also: `gameserver-auto-update on`, `off`, `status` and `log` (log file: `/var/log/gameserver-autoupdate.log`).

## Updating the LXC (gameserver-update-lxc)

`gameserver-update-lxc` updates the commands and `docker-compose.yml` of an installed LXC from this repository. It refuses unexpected branches and remotes, stops on local changes, backs up and verifies first, and keeps all game data, `passwords.env`, `.env` and settings. It restarts only when the compose file changed, and rolls back by itself if something fails. Start with `gameserver-update-lxc --dry-run`. Details, exit codes and rollback: [docs/update-lxc.md](docs/update-lxc.md). LXCs set up before it existed: [docs/migrate-existing-lxc.md](docs/migrate-existing-lxc.md).

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
  game.conf                    name, passwords, default CPU/RAM/disk (read by install.sh)
  profile.conf                 /etc/gameserver.conf for this game (paths, container, player query)
  docker-compose.yml           the game server
  passwords.env                password template (filled in on first launch)
  install-server-commands.sh   GENERATED: installs the commands inside the LXC
  README.md                    game info
lib/                           shared source of the commands (common.sh, update-lxc.sh, shell-init.sh,
                               gsquery.py, installer.sh = template of install-server-commands.sh)
tools/build-commands.py        generates games/*/install-server-commands.sh from lib/ + profile.conf
tools/lxc-inspect.sh           read-only inventory of an LXC (before a migration)
tests/                         sandboxed tests: install.sh on a fake Proxmox, shell startup, update-lxc (tests/run.sh)
docs/                          commands, update-lxc, migrating an existing LXC
mcp/docker-compose.yml         optional MCP server
server-names.txt               random server-name candidates
```

Never edit `games/*/install-server-commands.sh` by hand. Change `lib/` or `profile.conf` and run `python3 tools/build-commands.py`. CI fails if a generated file is out of date. Run the tests with `sudo tests/run.sh` (it needs root for a private mount namespace; the real system is not touched).

Every game folder has its own README with ports, passwords and LXC name.

## Submit a new game

Fork the repo, copy an existing folder in `games/` (e.g. `games/valheim`), adapt it, and open a pull request. [llm.txt](llm.txt) contains exact instructions, so you can also hand it to an LLM and ask it to add your game. Please add the game to the table above.

## License

Free to fork and use, MIT licensed.

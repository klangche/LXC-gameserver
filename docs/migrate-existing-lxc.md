# Migrating an existing (older) game LXC to the repository version

This brings an LXC that was set up by hand, or by an early version of these scripts, onto the
current repository, without losing world saves, player data, passwords or settings. After this,
future updates are a single `gameserver-update-lxc`.

What changes for you: all commands get the `gameserver-` prefix (`status` becomes
`gameserver-status`, `update` becomes `gameserver-update`, `server-help` becomes `gameserver-help`, and so on;
see [commands.md](commands.md)). The LXC no longer depends on the Proxmox VE community-scripts
helper. Files that helper put into the LXC (for example its own `/usr/bin/update`) are left alone and
listed by `gameserver-check`, so you can remove them yourself (step 7).

Each block is one command. Run them yourself, read the output, and only go on when it looks right.
Steps 1–3 change nothing in the LXC.

> The repository must contain gameserver-update-lxc on `main` (the pull request that adds it must be merged).
> To try it before that, put `REPO_BRANCH=<branch>` in `/etc/gameserver-repo.conf` and use
> `--branch <branch>` in step 4.

## 1. Proxmox host: find the container

```bash
pct list
```

Note the CTID of the game LXC (the name is `gameserver-<game>-<servername>`). Below it is called `<CTID>`.

## 2. Proxmox host: full backup of the whole LXC

This is the safety net for everything: game data, configuration, permissions, symlinks, Docker images.

```bash
pvesm status
```

Pick a storage with `backup` in its content and enough free space (for example `local`), then:

```bash
vzdump <CTID> --mode snapshot --compress zstd --storage local --notes-template "before gameserver-update-lxc {{guestname}}"
```

If the storage can't take snapshots, vzdump falls back to `suspend` mode. The game server pauses for
a moment, which is fine. Verify the backup:

```bash
ls -lh /var/lib/vz/dump/ | grep "vzdump-lxc-<CTID>-"
```

```bash
zstd -t /var/lib/vz/dump/vzdump-lxc-<CTID>-<time>.tar.zst
```

```bash
tar -I zstd -tf /var/lib/vz/dump/vzdump-lxc-<CTID>-<time>.tar.zst | grep -E '^\./opt/' | head -n 30
```

The last command must list your game folder (for example `./opt/enshrouded/game/savegame/...`).
**Write down the file name.** Restoring the whole LXC from it (only in an emergency; it replaces the LXC):
`pct restore <CTID> /var/lib/vz/dump/vzdump-lxc-<CTID>-<time>.tar.zst --force`.

If your storage supports it, a snapshot also gives you a fast way back:

```bash
pct snapshot <CTID> before_update_lxc
```

## 3. Inside the LXC: read-only inventory

```bash
pct enter <CTID>
```

```bash
curl -fsSL https://raw.githubusercontent.com/klangche/LXC-gameserver/main/tools/lxc-inspect.sh -o /root/lxc-inspect.sh
```

Read it first (it only reads; secrets are shown as `<hidden>`):

```bash
less /root/lxc-inspect.sh
```

```bash
bash /root/lxc-inspect.sh
```

The report is in `/root/lxc-inspect-<time>.txt`. Look at, or share, these parts:

- **Game server configuration**: is there an `/etc/gameserver.conf`? Without it, gameserver-update-lxc stops and the LXC needs a manual migration.
- **Game folder in detail**: does `docker-compose.yml` differ from `main`? Every difference is either an older version or your own change. Decide for each one whether to keep it.
- **Custom commands**: does an interactive shell run `/usr/local/bin/<name>` for every command? An alias or function there shadows the command.
- **Shell startup files**: old `alias`/function lines, `CUSTOM_CMDS`, `enshrouded-help`, `SYNTAX:` errors, and the list being printed more than once.
- **Docker**: the bind mounts (`bind /opt/<game>/... -> ...`) are where the game data is.

## 4. Inside the LXC: get the repository and preview

```bash
command -v git || apt-get install -y git
```

```bash
git clone --branch main https://github.com/klangche/LXC-gameserver.git /opt/lxc-gameserver
```

```bash
bash /opt/lxc-gameserver/lib/update-lxc.sh --dry-run
```

The dry run shows every difference as a diff, and whether it would be a game data migration. It
changes nothing. Exit code 2 means "needs your decision".

## 5. Decide about local differences

- A difference is only an **older version** (for example a missing environment line that `main` now has): take the repository version with `--force` in step 6.
- A difference is **your own change** that you want to keep (for example `SERVER_SLOTS`): it will be kept as `docker-compose.yml.local-<time>`. Re-apply it after step 6, and preferably add it to the repository or to `.env`.
- **GAME DATA MIGRATION** (volumes or container name differ): stop here. The data has to be moved by hand first. Ask before continuing.
- An **alias or function** in `/root/.bashrc` from the time before the repository (for example `alias update=...`): it no longer collides with anything, because every command now starts with `gameserver-`. Keep it or delete it (`nano /root/.bashrc`), as you like. The installer never removes your own aliases.

## 6. Inside the LXC: apply

```bash
bash /opt/lxc-gameserver/lib/update-lxc.sh --force
```

Leave out `--force` if the dry run showed no differences. gameserver-update-lxc shows the plan and asks, makes
and verifies its own backup (`/var/backups/gameserver/<time>`), updates, restarts only if the compose
file changed, and verifies. If anything fails it rolls back by itself (exit 3).

## 7. Inside the LXC: check

```bash
gameserver-check
```

```bash
gameserver-status
```

```bash
gameserver-versions
```

```bash
gameserver-serverlog
```

Then join the server from the game, and check that your world, characters and permissions are there.
Open a new shell (`bash`): the command list must appear exactly once.

If `gameserver-check` lists files from the community-scripts helper (`INFO ... comes from the Proxmox VE
community-scripts helper`), they are not used by this project. To stop using them, move them away
instead of deleting them, for example:

```bash
mv /usr/bin/update /root/update.community-scripts.bak
```

Run `gameserver-check` again afterwards.

## Undo

- Only the commands and configuration: `gameserver-update-lxc --rollback` (see [update-lxc.md](update-lxc.md)).
- Everything, the whole LXC: `pct rollback <CTID> before_update_lxc` (snapshot) or `pct restore` (vzdump), both on the Proxmox host.

## From now on

```bash
gameserver-update-lxc
```

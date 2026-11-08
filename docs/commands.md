# Commands in the game LXC

Every game LXC gets the same commands. They all start with **`gameserver-`**: type `gameserver-` and
press Tab to see them. They are small scripts in `/usr/local/bin` that load
`/usr/local/lib/gameserver/common.sh`. Because they are real files and not aliases or shell
functions, they work the same in a terminal, a script, cron and `ssh host <command>`.
`gameserver-help --full` prints this list with arguments and examples inside the LXC.

| Command | Arguments | What it does | Example |
|---------|-----------|--------------|---------|
| `gameserver-status` | – | Container status and the last 15 lines of the server log | `gameserver-status` |
| `gameserver-serverlog` | – | Live tail of the server log (Ctrl+C to quit) | `gameserver-serverlog` |
| `gameserver-start` | – | Start the game server (`docker compose up -d`) | `gameserver-start` |
| `gameserver-stop` | – | Stop the game server (`docker compose down`) | `gameserver-stop` |
| `gameserver-restart` | – | Stop and start the game server | `gameserver-restart` |
| `gameserver-update` | – | Back up the savegame, pull the newest image, update the game files, restart | `gameserver-update` |
| `gameserver-versions` | – | Image date, and the installed vs latest Steam build where known | `gameserver-versions` |
| `gameserver-backup` | – | Savegame backup to `/opt/<game>/backups/savegame-<time>.tar.gz` | `gameserver-backup` |
| `gameserver-password` | – | Edit all passwords (`passwords.env`) in nano; run `gameserver-restart` afterwards. Same: `gameserver-passwords` | `gameserver-password` |
| `gameserver-logs` | – | Live container logs (last 100 lines, then follow) | `gameserver-logs` |
| `gameserver-auto-update` | `[on\|off\|status\|log]` | Automatic game updates. Without an argument it asks 3 questions (see the README) | `gameserver-auto-update status` |
| `gameserver-update-lxc` | `[--dry-run] [--force] [--saves-only] [--allow-volume-change] [--yes]`, `--rollback [DIR]`, `--help` | Update these commands and the compose file from the Git repository. Game data is kept. See [update-lxc.md](update-lxc.md) | `gameserver-update-lxc --dry-run` |
| `gameserver-check` | – | Look for aliases or functions that shadow the commands, leftovers of older versions, broken startup files, and shells that print the list twice or print anything when not interactive. Changes nothing | `gameserver-check` |
| `gameserver-help` | `[--full]` | The command list; `--full` adds arguments and examples. Same: `lxc-gameserver-help` | `gameserver-help --full` |

`gameserver-update` updates the **game** (image and server files). `gameserver-update-lxc`
updates the **server commands** of the LXC from Git. Neither touches world saves, `passwords.env`
or `.env`.

## Why the prefix

Older versions installed short names: `start`, `stop`, `status`, `update`, `server-help`, and so on.
Those collide with other tools. The LXC is created by the Proxmox VE community-scripts Docker helper,
which installs its own `update` command (`/usr/bin/update`, its updater). Our `/usr/local/bin/update`
silently hid it, because `/usr/local/bin` comes first in `PATH`. A personal `alias update=…` in
`/root/.bashrc` hid ours in turn, but only in interactive shells. With `gameserver-` in front, none
of these can collide.

The installer (and so `gameserver-update-lxc`) removes the old short names, but only when the file
is exactly one of our own small stubs. Any other file with such a name is left alone and reported.
Everything the community-scripts helper installs (its `update` command, its login messages) is used
as it is and never changed. `gameserver-check` mentions such files only as information.

## When the list is shown

The command list (`gameserver-help`) is shown once each time an interactive bash shell starts:

| How the shell starts | Read by | Shown |
|----------------------|---------|-------|
| `pct enter <id>`, a new terminal, typing `bash` | `/etc/bash.bashrc` | yes, once |
| login: `ssh host`, `su -`, console, `bash -l` | `/etc/profile` → `/etc/bash.bashrc`, `/etc/profile.d/zz-gameserver.sh` | yes, once |
| `bash` inside a shell (a new shell) | `/etc/bash.bashrc` | yes, once for the new shell |
| `. /etc/bash.bashrc` again in the same shell | – | no (already shown) |
| scripts, cron, systemd, `ssh host cmd`, `bash -c`, `bash -ic 'cmd'`, scp/rsync | – | no, nothing is printed and exit codes are unchanged |

How it works: `/etc/bash.bashrc` and `/etc/profile.d/zz-gameserver.sh` each contain one line that
sources `/usr/local/lib/gameserver/shell-init.sh`. That file returns at once unless the shell is
interactive (`$-` contains `i`) and is not running `bash -c`. It sets a guard variable,
`GS_BANNER_SHOWN`. The guard is not exported, so re-sourcing a startup file doesn't print the list
again, but a new `bash` does. To turn the list off for one shell, use `GS_NO_BANNER=1 bash`.

The block in `/etc/bash.bashrc` sits between `# >>> gameserver commands >>>` and
`# <<< gameserver commands <<<`. Re-running the installer replaces it there. Nothing else in the
file is changed, except the exactly known old blocks below.

## Cleanup of old versions

The installer removes these leftovers. It copies each file first (`<file>.bak-gameserver-<time>`)
and only writes the change if the file is still valid bash:

- the `GAMESERVER_COMMANDS` block in `/etc/bash.bashrc` (it printed the list without a guard and
  defined `alias help=server-help`, which hid the bash builtin `help`)
- the hand-made `# CUSTOM_CMDS` block in `/etc/bash.bashrc` (only if it ends with `fi` within 40 lines)
- `enshrouded-help` in `/root/.bashrc` (the line becomes `:`, so a surrounding `if … fi` stays valid)
- the old short-name commands in `/usr/local/bin` (only our own stubs)

Your own aliases and functions are never removed. If one has the same name as a `gameserver-`
command, `gameserver-check` reports it.

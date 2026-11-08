# Commands in the game LXC

Every game LXC gets the same commands. They are small scripts in `/usr/local/bin` that load
`/usr/local/lib/gameserver/common.sh`. Being real files, not aliases or shell functions, they work
the same way in a terminal, a script, cron and `ssh host <command>`.
`server-help --full` prints this list, with arguments and examples, inside the LXC.

| Command | Arguments | What it does | Example |
|---------|-----------|--------------|---------|
| `status` | – | Container status and the last 15 lines of the server log | `status` |
| `serverlog` | – | Live tail of the server log (Ctrl+C to quit) | `serverlog` |
| `start` | – | Start the game server (`docker compose up -d`) | `start` |
| `stop` | – | Stop the game server (`docker compose down`) | `stop` |
| `restart` | – | Stop and start the game server | `restart` |
| `update-game` | – | Back up the savegame, pull the newest image, update the game files, restart | `update-game` |
| `update` | – | Old name for `update-game`; still works and prints a note | `update` |
| `versions` | – | Image date, and the installed vs latest Steam build where known | `versions` |
| `backup` | – | Savegame backup to `/opt/<game>/backups/savegame-<time>.tar.gz` | `backup` |
| `password` | – | Edit all passwords (`passwords.env`) in nano; run `restart` afterwards. Same: `passwords`, `lösenord` | `password` |
| `logs` | – | Live container logs (last 100 lines, then follow) | `logs` |
| `auto-update` | `[on\|off\|status\|log]` | Automatic game updates. Without an argument it asks 3 questions (see the README) | `auto-update status` |
| `update-lxc` | `[--dry-run] [--force] [--saves-only] [--allow-volume-change] [--yes]`, `--rollback [DIR]`, `--help` | Update these commands and the compose file from the Git repository. Game data is kept. See [update-lxc.md](update-lxc.md) | `update-lxc --dry-run` |
| `server-check` | – | Look for aliases or functions that shadow the commands, old banner lines, broken startup files, and shells that print the list twice or print anything when not interactive. Changes nothing | `server-check` |
| `server-help` | `[--full]` | The command list; `--full` adds arguments and examples | `server-help --full` |

`update-game` and `update-lxc` are separate on purpose. `update-game` updates the **game**
(image, server files). `update-lxc` updates the **server commands** of the LXC from Git. Neither
one touches world saves, `passwords.env` or `.env`.

## When the list is shown

The command list (`server-help`) is shown once each time an interactive bash shell starts:

| How the shell starts | Read by | Shown |
|----------------------|---------|-------|
| `pct enter <id>`, a new terminal, typing `bash` | `/etc/bash.bashrc` | yes, once |
| login: `ssh host`, `su -`, console, `bash -l` | `/etc/profile` → `/etc/bash.bashrc`, `/etc/profile.d/zz-gameserver.sh` | yes, once |
| `bash` inside a shell (a new shell) | `/etc/bash.bashrc` | yes, once for the new shell |
| `. /etc/bash.bashrc` again in the same shell | – | no (already shown) |
| scripts, cron, systemd, `ssh host cmd`, `bash -c`, `bash -ic 'cmd'`, scp/rsync | – | no, nothing is printed and exit codes are unchanged |

How it works: `/etc/bash.bashrc` and `/etc/profile.d/zz-gameserver.sh` each contain one line that
sources `/usr/local/lib/gameserver/shell-init.sh`. That file returns at once unless the shell is
interactive (`$-` contains `i`) and is not running `bash -c`. It also sets a guard variable,
`GS_BANNER_SHOWN`. The guard is not exported, so re-sourcing a startup file in the same shell
doesn't print the list again, but a new `bash` does. To turn the list off for one shell, use
`GS_NO_BANNER=1 bash`.

The block in `/etc/bash.bashrc` sits between `# >>> gameserver commands >>>` and
`# <<< gameserver commands <<<`. Re-running the installer replaces it there. Nothing else in the
file is changed, except the exactly known old blocks listed below.

## Cleanup of old versions

`install-server-commands.sh` (and so `update-lxc`) removes these leftovers from earlier versions.
It copies each file first (`<file>.bak-gameserver-<time>`) and only writes the change if the file is
still valid bash:

- the `GAMESERVER_COMMANDS` block in `/etc/bash.bashrc` (it printed the list without a guard and
  defined `alias help=server-help`, which hid the bash builtin `help`)
- the hand-made `# CUSTOM_CMDS` block in `/etc/bash.bashrc` (only if it ends with `fi` within 40 lines)
- `enshrouded-help` in `/root/.bashrc` (the line becomes `:`, so a surrounding `if … fi` stays valid)

Your own aliases and functions are never removed. If one has the same name as a command (for
example an old `alias update=…` in `/root/.bashrc`), it wins in interactive shells only, so the
command behaves differently in a terminal than in scripts. `server-check` reports this; remove the
alias by hand.

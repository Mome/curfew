# curfew

`curfew` applies an [hblock](https://github.com/hectorm/hblock) website-blocking profile, then
locks you out of `sudo` via [`nosudo`](https://github.com/mome/nosudo) for the same duration — so
you can't undo the block early. This walks through setting up and running your first curfew.

## Prerequisites

- `nosudo` installed and on your `PATH`.
- `hblock` installed and on your `PATH`.
- `curfew` itself on your `PATH` — see Installation below (or run it by path, e.g. `./curfew`).

## Installation

There's no packaging/build step — `curfew` is a single script that finds its bundled `profiles/`
directory relative to its own real location (following symlinks), so installing it is just a
symlink onto your `PATH`, managed via the bundled Makefile:

```sh
make install      # symlinks curfew into ~/.local/bin (override with PREFIX=...)
```

Update by `git pull`ing this repo — the symlink always points at the current checkout, no
reinstall needed.

```sh
make uninstall     # removes the installed symlink only — profiles in ~/.config/curfew are kept
make purge         # uninstall, plus deletes ~/.config/curfew (your profiles)
```

### Shell completion (bash)

`make install` also symlinks `completions/curfew.bash` into
`~/.local/share/bash-completion/completions/curfew`, which the
[bash-completion](https://github.com/scop/bash-completion) package auto-loads per-command in new
shells. If you don't have `bash-completion` set up, source it directly instead, e.g. in
`~/.bashrc`:

```sh
source ~/repos/curfew/completions/curfew.bash   # or wherever this repo lives
```

It completes profile names (yours and bundled), `--list`/`--new`/`--help`, `--for`/`--until` after
a profile, and `--from` after `curfew --new <name>`.

### Shell completion (fish)

`make install` also symlinks `completions/curfew.fish` into
`~/.config/fish/completions/curfew.fish`, which fish auto-loads — no sourcing or extra package
needed. Without running `make install`, source it directly instead:

```fish
source ~/repos/curfew/completions/curfew.fish   # or wherever this repo lives
```

Same coverage as the bash completion: profile names (yours and bundled),
`--list`/`--new`/`--help`, `--for`/`--until` after a profile, and `--from` after `curfew --new
<name>`.

## 1. Compose a profile from bundled profiles

The fastest way to start is to **inherit** from the profiles bundled with curfew — see `curfew
--list`'s "Bundled profiles" section (sourced from `./profiles/` next to the script: `reddit`,
`video`, `news`, `shopping`, `games`, `social-media`, `entertainment`, and more):

```sh
curfew --new work --from entertainment,news,shopping
```

This creates `~/.config/curfew/profiles/work/parents.list` — one profile name per line, `#`
comments allowed. **Inheritance is live**: at apply time, curfew resolves the full chain of
parents (and their own parents, and so on) and merges everyone's `sources.list`/`deny.list`/
`allow.list` together — so `entertainment` here pulls in `games`, `memes`, `reddit`,
`social-media`, `sports`, and `video` automatically, and if you (or a future update) edits any of
those later, `work` picks up the change without needing to be recreated.

A user profile of the same name as a bundled one shadows it (your own `~/.config/curfew/profiles/`
is checked before the bundled `profiles/` directory) — useful if you want to fully customize a
bundled profile without giving up its name.

Use `curfew --list` any time to see what profiles exist, which list files each one has, and what
they inherit from.

## 2. Create a custom profile

Prefer to curate your own domains, or nothing bundled fits? Scaffold an empty profile:

```sh
curfew --new focus
```

This creates `~/.config/curfew/profiles/focus/` with three empty files (plus the `parents.list`
inheritance file from above — four in total):

```
sources.list   # blocklist URLs, one per line — fed to hblock -S
deny.list      # domains you want blocked yourself, one per line — hblock -D
allow.list     # exceptions carved out of the above, one per line — hblock -A
```

All three are optional — a missing file just means that piece isn't passed to `hblock` at all
(so `hblock` falls back to its own built-in list for that piece, rather than to an empty one).
Delete a file if you don't want its default.

All three support `#` comments (full-line or trailing, e.g. `reddit.com  # too tempting`) —
`hblock` strips them before parsing.

For a first profile, `deny.list` alone is enough:

```sh
echo "reddit.com" >> ~/.config/curfew/profiles/focus/deny.list
echo "news.ycombinator.com" >> ~/.config/curfew/profiles/focus/deny.list
```

Combine both approaches freely — a hand-curated profile can also carry its own `parents.list` to
inherit from bundled or other user profiles.

## 3. Apply it

```sh
curfew focus --for 2h
```

or block until a specific time:

```sh
curfew focus --until 18:00
```

Anything after the profile name and duration is passed straight through to `nosudo restrict`, so
you can target another user the same way `nosudo` supports:

```sh
curfew focus alice --until 18:00
```

What this does, in order:

1. Backs up your current `/etc/hosts` to `/var/lib/curfew/hosts.bak`.
2. Resolves the profile's full inheritance chain and merges every ancestor's lists together.
3. Runs `hblock` with the merged lists, writing your original `/etc/hosts` content back to the
   top of `/etc/hosts` (for readability) and the blocklist below it — so anything you already had
   there (e.g. local dev hostnames, VPN entries) still resolves, *including*, since `/etc/hosts`
   matches first-entry-wins, any domain you'd already mapped yourself that's also on the
   blocklist — that one domain won't be blocked for the curfew's duration.
4. *Only if the profile (or anything it inherits from) has a `block-games` file:* locks the
   installed games it detects — see [6. Lock installed games](#6-lock-installed-games-optional).
5. Installs a reboot-safe systemd timer that will restore your original `/etc/hosts` (and unlock
   any locked games) at the same time your `sudo` access comes back.
6. Runs `nosudo restrict` to lock your own `sudo` access for the given duration — the last step,
   since everything above still needs `sudo` calls of its own.

Expect a password prompt (`nosudo restrict` re-execs under `sudo`).

## 4. Check status

`curfew` doesn't have its own status command — check `nosudo`'s, since the hosts-restore is keyed
to the same lift time:

```sh
nosudo status
```

## 5. What happens when it lifts

At the scheduled time, a systemd timer runs as root and:

- Copies `/var/lib/curfew/hosts.bak` back over `/etc/hosts`.
- Unlocks any games locked for this curfew, restoring each one's original owner and permissions
  from `/var/lib/curfew/apps.bak` (and re-enabling any disabled snaps).
- Disables and removes itself (the timer, its service unit, the backups, and its own restore
  script).

`nosudo`'s own restore timer lifts your `sudo` access at the same moment, independently.

## 6. Lock installed games (optional)

Website blocking doesn't stop games already installed on the machine. A profile can also **lock
installed games** for the curfew's duration, by containing a file named `block-games` (its
contents are ignored — an empty file is fine). Like the list files, it's inherited: if any profile
in the chain has it, games get locked.

The bundled `games` profile has this file, so `curfew games --for 2h` blocks game websites *and*
locks installed games. Since `entertainment` inherits `games`, anything built on it (like the
`work` example above) locks installed games too.

To opt in on a profile of your own:

```sh
touch ~/.config/curfew/profiles/focus/block-games
```

To get the bundled `games` website blocking *without* locking installed games, shadow it with your
own profile of the same name (`~/.config/curfew/profiles/games/`, with a `deny.list` but no
`block-games`) — a user profile always wins over the bundled one.

**Always preview first.** Locking happens right before `nosudo` takes your `sudo` away, so if
something gets locked that shouldn't be, you can't undo it until the curfew lifts. See exactly
what would be locked — this changes nothing and needs no `sudo`:

```sh
curfew --detect-games
```

Each candidate is listed as `block` (would be locked) or `skip` (never locked, with the reason).

### What gets detected

- **Desktop entries** with a `Game` category, in `~/.local/share/applications` and
  `/usr/share/applications` (and `/usr/local/share/applications`). This covers games installed via
  apt, pacman, the AUR, and anything else that installs a menu entry, including AppImages you've
  added to your menu. The program the entry launches is locked.
- **Flatpak** games (via their exported menu entries). The app's installed files are locked, so
  `flatpak run` fails too, not just the menu entry.
- **Snap** games (via their exported menu entries). The snap is disabled with `snap disable`.
- **Steam** games, from every Steam library (`libraryfolders.vdf`), including the Flatpak Steam
  client's. The game's install directory is locked. Proton, the Steam Linux Runtime and the
  Steamworks redistributables are never locked, since every other game depends on them.

Not detected: games managed by **Lutris, Heroic, Bottles, PlayOnLinux**, or any other launcher
that keeps its games in its own database — unless you've added a desktop menu entry for the game.

### How locking works

A locked file or directory is made owned by `root` with no permissions at all (`chown root:root`,
`chmod 000`). Both are needed: a plain `chmod` on a file you own (like a Steam library in your home
directory) could be undone with your own `chmod`, no `sudo` required, and a file that's merely
non-executable can still be copied and the copy run. The original owner and permissions of
everything locked are recorded first, and restored exactly when the curfew lifts.

To avoid ever breaking the system, curfew **never** locks:

- anything a game launches *through*: `steam`, `flatpak`, `snap`, `wine`, `python`, `sh`,
  `gamemoderun`, `lutris`, and similar launchers and interpreters;
- anything in system directories (`/bin`, `/usr/lib`, `/etc`, `/var`, …), except game
  directories like `/usr/games`;
- a program directly in `/usr/bin` unless it's named after the game's menu entry (packaged games
  usually are; a misconfigured entry pointing at a shared tool usually isn't).

**Games on NTFS or exFAT drives can't be locked** — those filesystems ignore Unix owners and
permissions. curfew checks every lock and prints a warning for any that didn't take.

Locking is friction, not a vault: you could still, for example, reinstall a locked Steam game into
a new folder during the curfew. It removes the one-click path, which is the point.

## Troubleshooting

**"a curfew hosts-block is already active"** — only one curfew block can run at a time, since
`/etc/hosts` is a single system-wide file. Wait for the active one to lift, or restore manually:

```sh
sudo cp /var/lib/curfew/hosts.bak /etc/hosts
```

**"cycle detected in profile inheritance: a -> b -> a"** — two profiles' `parents.list` files
inherit from each other (directly or transitively). Fix the cycle by editing one profile's
`parents.list`; `curfew --new` itself can't create a cycle (it only ever points at profiles that
already exist), so this only happens from hand-editing `parents.list`.

**hblock, a game lock, or `nosudo restrict` fails partway through `curfew ... --for ...`** —
`curfew` rolls back what it already did (removes the hosts backup if `hblock` failed; restores
`/etc/hosts` and unlocks any games already locked if a later step failed), so you're left in your
original state either way rather than half-blocked.

**"warning: … is NOT locked — its filesystem ignores Unix permissions"** — that game lives on an
NTFS or exFAT drive (common for Steam libraries shared with Windows), where locking has no effect.
The rest of the curfew still applies.

**"not restoring …: it was moved or replaced during the curfew"** — a locked game's path was
replaced (e.g. by a symlink) while it was locked, so the restore refused to touch whatever the path
now points at. Check what's there, then restore the original by hand if it still exists.

**I need out before the timer fires** — `nosudo`'s own lock prevents exactly this; that's the
point. The hosts block alone can be lifted early with the manual `cp` above, but your `sudo`
access stays locked until `nosudo`'s timer fires.

# curfew — Specification

> A bash CLI that **applies an hblock website-blocking profile to `/etc/hosts` and locks the
> invoking user's `sudo` rights for a bounded period**, so the block can't be undone before it
> lifts. The hosts-file change **merges with, rather than overwrites,** the existing file, and
> both the block and the restore are **reboot- and crash-safe**. Profiles can **inherit** from
> other profiles, including a set bundled with curfew itself.

This document is the living specification. It records *what* the software does and *every
important decision together with the reason for it*.

An earlier version of this document described a from-scratch Python rewrite of curfew,
reimplementing hblock's blocklist fetch/parse logic via `python-hosts` and consuming `nosudo` as
a Python library. That approach was **rejected** in favor of keeping curfew a thin bash script
that shells out to `hblock` and `nosudo` — reimplementing hblock added complexity (fetch/parse/
merge logic, caching, a new dependency graph) for no benefit over just using hblock correctly.
See §2 for how the one real gap in the original bash prototype (hblock overwrote `/etc/hosts`
wholesale) was closed without a rewrite.

---

## 1. Goal

Let a user voluntarily block a set of websites (a *profile*) and remove their own ability to
undo the block early, for a chosen period. This composes two independent primitives:

1. **A hosts-file block** (via `hblock`) — domains resolve to a non-routable address for the
   duration.
2. **A sudo lock** (via the `nosudo` CLI as a subprocess) — the user cannot edit `/etc/hosts`,
   kill the restore timer, or otherwise undo #1 before the lock lifts, because both require root.

Point #2 is what makes #1 binding rather than a suggestion — see `nosudo`'s own specs.md for why
removing your own sudo is self-reinforcing.

**Scope:** one profile, one active curfew system-wide at a time (§6). Multiple concurrent
curfews are out of scope.

---

## 2. How merging & reboot/crash safety work

### Merge, don't overwrite

hblock itself always **replaces its output file wholesale** — it has no built-in way to merge
with an existing hosts file. curfew works around this using hblock's own `-O`/`-H`/`-F` flags
rather than reimplementing hblock's fetch/parse/write logic:

- `-O /etc/hosts` — hblock writes directly to the real hosts file.
- `-H none` — suppress hblock's own header boilerplate.
- `-F "$HOSTS_BACKUP"` — hblock appends the **pre-curfew `/etc/hosts`, included verbatim with no
  parsing**, after its own blocklist.

Since `/etc/hosts` resolution honors the **first matching entry** for a given name, the
blocklist — now physically first in the file — wins for any domain the user had also mapped
themselves, while everything else in their original file survives untouched below it. This gets
the same practical outcome as a from-scratch merge implementation (block wins on conflict,
everything else preserved) with a few lines of shell instead of a new hosts-file-parsing
dependency.

### Reboot/crash-safe restore

Mirrors `nosudo`'s own restore design (state on disk, a systemd timer with an absolute
`OnCalendar` time and `Persistent=true`, a root-owned restore script that needs no
curfew/`nosudo`/Python at lift time):

1. **The block itself** is on-disk lines in `/etc/hosts` — surviving reboot is automatic.
2. **The restore trigger** is a systemd `.timer` + `.service` pair
   (`curfew-restore-hosts.{timer,service}`), `OnCalendar` set to the same lift time `nosudo
   restrict` computed, `Persistent=true` so a missed restore fires on next boot.
3. **The restore action** is a self-contained, root-owned `0700` shell script
   (`/var/lib/curfew/restore-hosts.sh`, coreutils only): `cp -f` the pre-curfew backup back over
   `/etc/hosts`, then disable/remove the timer, service, backup, and itself.
4. **State** is implicit, not a separate JSON file: the existence of
   `/var/lib/curfew/hosts.bak` *is* the "a curfew is active" signal (§6).

The two locks (hosts + sudo) are entirely independent systemd timers, each armed with the same
lift time at apply time, each reboot/crash-safe on its own — they don't coordinate at restore
time, only at apply time (`curfew` reads `nosudo status`'s freshly-computed lift time once, to
arm its own timer to match).

---

## 3. Command surface

| Command                                    | Description                                                          |
|---------------------------------------------|-----------------------------------------------------------------------|
| `curfew <profile> --for <duration>`        | Apply profile, lock sudo for a relative duration, e.g. `--for 2h`.    |
| `curfew <profile> --until <time>`          | Apply profile, lock sudo until an absolute time, e.g. `--until 18:00`.|
| `curfew --list`                            | List available profiles: yours, then bundled ones.                   |
| `curfew --new <profile> [--from a,b,c]`    | Scaffold a new profile, optionally inheriting others.                 |

Unlike `nosudo`, there is no per-user targeting flag: a curfew always applies to the invoking
user by default (a system-wide hosts block can't be scoped to one user anyway), though a target
user can still be passed through to `nosudo restrict` as a trailing argument.

There is no `curfew restore`, `curfew status`, or `--dry-run` — see §8 (carried forward from the
earlier plan as explicitly deferred, not implemented).

### Profiles

A directory under `$CURFEW_PROFILES_DIR` (default `~/.config/curfew/profiles/<name>/`), or one
of the profiles bundled with curfew itself (in `./profiles/`, next to the script — checked as a
fallback if a name isn't found under `$CURFEW_PROFILES_DIR`), containing any of:

- `sources.list` — blocklist URLs, one per line (`hblock -S`).
- `deny.list` — the user's own domains to block, one per line (`hblock -D`).
- `allow.list` — exceptions, one per line (`hblock -A`).
- `parents.list` — names of other profiles to inherit from, one per line.

All four are optional. `#` comments (full-line or trailing) and blank lines are stripped from
all four before use.

### Inheritance

A profile's `parents.list` names other profiles (user or bundled) to inherit from. Resolution is
**live**: every `curfew <profile> --for/--until` walks the full chain of `parents.list` files
(ancestors of ancestors, and so on) fresh, so editing a parent profile later automatically
affects everything that inherits from it — there is no one-time copy or snapshot. Diamond
inheritance (the same ancestor reached via two different paths) is deduped; a cycle is detected
and refused with a clear error naming the cycle. Merge order (ancestors before self) is
deterministic but not load-bearing for correctness: hblock builds the full deny+sources domain
set and then subtracts the allow set as a separate step, so which profile's line came first in
the merged input never changes hblock's output.

A user profile shadows a bundled profile of the same name (user profiles are resolved first).

---

## 4. Bundled profiles

curfew ships a set of ready-to-use profiles in `./profiles/` (resolved relative to the script's
own location, so they work immediately after cloning the repo — no separate install/packaging
step). See `curfew --list` for the current set; as of this writing it includes per-platform
social-media profiles (`facebook`, `instagram`, `pinterest`, `tiktok`, `twitter`, aggregated
under `social-media`), a language split for news (`news-en`, `news-de` — content is
language/region-dependent, e.g. `tagesschau.de` vs `cnn.com`), and single-category profiles
(`reddit`, `youtube`, `games`, `shopping`, `gambling`, `adult-content`, etc.) meant to be composed
via `--from` into a personal profile rather than used alone.

---

## 5. Decisions and rationale

| Decision                              | Choice                                       | Why                                                                                                 |
|----------------------------------------|-----------------------------------------------|-------------------------------------------------------------------------------------------------------|
| Blocklist fetching/merging             | Delegate entirely to `hblock` (`-O`/`-H`/`-F`)| Reimplementing hblock's fetch/parse/write was explicitly rejected — adds a dependency and a maintenance burden for something hblock already does. |
| Hosts-file merge mechanism             | `-F` (footer) holds the pre-curfew backup     | First-match-wins resolution means the blocklist (written first) wins on conflicts, while the footer preserves everything else verbatim — no hosts-syntax parsing needed. |
| `nosudo` integration                   | subprocess (`nosudo restrict ...`), not a library | curfew stays a single bash script with no language/dependency coupling to `nosudo`'s Python package. |
| Inheritance model                      | Live/dynamic, resolved at apply time          | A shared bundled profile (e.g. `news-en`) can be updated once and every profile that inherits from it picks up the change automatically — a one-time-copy model would let profiles silently drift. |
| Bundled profile location               | `./profiles/` next to the script, resolved via `${BASH_SOURCE[0]}` | Works immediately after a git clone; no packaging/install mechanism exists for curfew as a distributed artifact yet, so solving that is out of scope. |
| Profile lookup order                   | User profiles, then bundled                   | Lets a user profile shadow (fully override) a bundled one of the same name without curfew needing to special-case or refuse the name collision. |
| Merging multiple profiles' lists       | curfew concatenates into temp files itself, not multiple hblock flags | Confirmed via hblock's own source: `-S`/`-D`/`-A` do **not** accumulate across repeated flags — each occurrence overwrites the previous value. hblock has no way to combine multiple source files itself. |
| One active curfew at a time            | existence of `$HOSTS_BACKUP` gates a second apply | Matches `nosudo`'s own per-user "already restricted" refusal in spirit; concurrent profiles would need independent tracked-state and independent timers for marginal benefit. |
| No `curfew restore`/`status`/`--dry-run` | deferred (§8)                                | Not part of the current scope; see §8 for what they'd need if built. |

---

## 6. Single active curfew

Only one curfew hosts-block may be active system-wide at a time, since `/etc/hosts` is a single
file: `cmd_apply` refuses to start a second one while `/var/lib/curfew/hosts.bak` exists (checked
via `sudo test -f`, since the file is root-owned).

---

## 7. Dependency on `nosudo`

Curfew depends on the `nosudo` CLI being installed and on `PATH` — it shells out to `nosudo
restrict <args>` and `nosudo status`, and depends on `nosudo status`'s output format (parsed with
`sed` to extract the lift time) to arm its own hosts-restore timer at the same time. No Python
dependency, no library coupling — `nosudo`'s own `src/nosudo/api.py` (a library-API extraction
done during an earlier, since-rejected plan for curfew) is not used by curfew at all.

---

## 8. Open questions / future work

Carried forward from the earlier (rejected) Python-rewrite plan — these are genuinely useful
ideas that just weren't implemented in this pass. If built, they should stay bash-native and
reuse the existing backup-file/systemd-timer mechanism above — **not** a Python/state-file
architecture, since that depended on the rewrite that was rejected.

- **`curfew restore`** — a dedicated command for manual early restore, folding in both halves
  (the hosts block and `nosudo restore`) in one invocation, rather than today's manual
  `sudo cp $HOSTS_BACKUP /etc/hosts` (which only handles the hosts half).
- **`curfew status`** — surface the hosts-block half directly (today, `nosudo status` only
  covers the sudo half; you have to infer the hosts-block is active from that).
- **`--dry-run`** — show the resolved profile chain, merged lists, and intended hblock/nosudo
  actions without touching the system.
- **Caching fetched blocklists** — hblock re-fetches `sources.list` URLs on every apply; no
  caching today.
- Closing other bypass paths (VPN, DNS-over-HTTPS, alternate resolvers) is explicitly out of
  scope — curfew only ever claims to gate the standard `/etc/hosts` resolution path.

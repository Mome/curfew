# curfew — Implementation Plan

Implements the specification in [specs.md](specs.md). This is a single bash script (`curfew`, at
the repo root) with no build step; this document records the mechanism behind the
profiles-with-inheritance feature, for anyone changing it later.

An earlier version of this document described a from-scratch Python rewrite (fetch/parse
blocklists directly, `python-hosts` for merging, `nosudo` as a library, a JSON state file). That
plan was rejected — see specs.md's intro — in favor of the mechanism below, which keeps `hblock`
and the `nosudo` CLI as subprocess dependencies and adds inheritance as a thin layer on top.

---

## 1. Script-scoped setup

Right after `PROFILES_DIR=`, resolve the script's own real directory (following symlinks) and
derive a bundled-profiles path from it:

```bash
_curfew_source="${BASH_SOURCE[0]}"
while [[ -L "$_curfew_source" ]]; do
  _curfew_dir="$(cd -P "$(dirname "$_curfew_source")" >/dev/null 2>&1 && pwd)"
  _curfew_source="$(readlink "$_curfew_source")"
  [[ "$_curfew_source" != /* ]] && _curfew_source="$_curfew_dir/$_curfew_source"
done
SCRIPT_DIR="$(cd -P "$(dirname "$_curfew_source")" >/dev/null 2>&1 && pwd)"
unset _curfew_source _curfew_dir

BUILTIN_PROFILES_DIR="${CURFEW_BUILTIN_PROFILES_DIR:-$SCRIPT_DIR/profiles}"
```

With curfew at the repo root, `SCRIPT_DIR` is the repo root and `BUILTIN_PROFILES_DIR` resolves
to `profiles/`. `CURFEW_BUILTIN_PROFILES_DIR` mirrors `CURFEW_PROFILES_DIR`, mainly so both can be
pointed at temp dirs during testing (see Verification below) without touching the real tree.

## 2. `parents.list` parsing

```bash
list_parents() {
  local parents_file="$1"
  [[ -f "$parents_file" ]] || return 0
  sed -e 's/#.*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$parents_file" \
    | grep -v '^$' || true
}
```

The trailing `|| true` matters under `pipefail`: `grep -v` exits 1 on no matches (empty/
all-comment file), a legitimate non-error result here.

## 3. `resolve_profile_dir <name> [context]`

Checks `$PROFILES_DIR/<name>` first, then `$BUILTIN_PROFILES_DIR/<name>`. Prints the resolved
directory and returns 0, or prints a clear "looked in: ..." error to stderr and returns 1 (never
`exit`s, so every call site composes it via `||`).

## 4. `resolve_profile_chain <name>` — cycle detection

DFS over `parents.list`, using two associative arrays as traversal state:
`_chain_in_progress` (current DFS stack → cycle detection) and `_chain_visited` (already
resolved → diamond dedup). Returns an ordered list of profile directories, ancestors-before-self,
via the `_chain_result` array.

**Call it via command substitution, never process substitution**, at the one call site
(`cmd_apply`):

```bash
chain_output="$(resolve_profile_chain "$profile")" || exit 1
mapfile -t chain_dirs <<<"$chain_output"
```

`mapfile -t x < <(resolve_profile_chain ...)` would silently swallow a cycle failure: a process
substitution's producer runs in a subshell, and that subshell's exit status is invisible to
`set -e` / the consuming command. `$(...) || exit 1` (command substitution) propagates it
correctly.

## 5. Merging into `hblock_args`

hblock's `-S`/`-D`/`-A` each take exactly one file and **do not accumulate** across repeated
flags (confirmed by reading hblock's own option-parsing code: each occurrence is a scalar
assignment, overwriting the previous value) — so curfew must concatenate multiple profiles'
lists itself before invoking hblock once.

Must preserve an existing subtlety: an **existing-but-empty** list file still causes its flag to
be passed (explicit empty list to hblock); a **missing** file omits the flag entirely (hblock's
own built-in default). Extended to a chain: omit the flag only if *no* profile in the whole chain
has that file at all.

```bash
merge_profile_lists() {
  local out="$1" kind="$2"; shift 2
  local dir any_file_present=0
  : > "$out"
  for dir in "$@"; do
    [[ -f "$dir/$kind" ]] || continue
    any_file_present=1
    if [[ -s "$dir/$kind" ]]; then
      printf '# from profile: %s\n' "$(basename "$dir")" >> "$out"
      cat "$dir/$kind" >> "$out"
      printf '\n' >> "$out"
    fi
  done
  [[ "$any_file_present" -eq 1 ]]
}
```

Called as `merge_profile_lists "$out" sources.list "${chain_dirs[@]}" && hblock_args+=(-S
"$out")` — a bare `cmd1 && cmd2` statement where `cmd1` legitimately fails (no profile in the
chain has that file) does **not** trigger `set -e`: per bash's documented `errexit` exemptions,
a command on the left side of `&&` is exempt, and this whole list is a standalone top-level
statement in `cmd_apply` (not itself the tail of an unguarded function call — see the pitfall in
§7 below for the case where that distinction matters).

Temp files live in a `mktemp -d` directory, cleaned up via `trap 'rm -rf "$merge_dir"' EXIT`
(not `RETURN` — `cmd_apply` has several mid-function `exit 1`s that a `RETURN` trap wouldn't
fire on; `EXIT` fires on all of them). Scoped inside `cmd_apply` only — safe, since `main`
dispatches to exactly one subcommand per process.

## 6. `cmd_apply` ordering

All new profile/chain logic runs **before** the first `sudo` call, so it's testable without root:

1. `resolve_profile_dir "$profile"` — unknown-profile check (no sudo)
2. `--for`/`--until` arg check (no sudo)
3. `resolve_profile_chain` — cycle/missing-parent detection (no sudo)
4. build `merge_dir` + `hblock_args` (no sudo)
5. `sudo test -f "$HOSTS_BACKUP"` — active-curfew guard (first sudo touch)
6. unchanged: `resolve_target_user`, hosts backup, `sudo hblock`, `nosudo restrict`, timer install

## 7. `cmd_new --from <a,b,c>`

Validates every named parent resolves (via `resolve_profile_dir`) *before* creating anything.
Writes validated names to `$dir/parents.list` (empty file if `--from` wasn't given, for
consistency with the other three always-created files). Splitting the comma-separated list:

```bash
IFS=',' read -ra parent_names <<<"$from_csv"
```

**Pitfall avoided:** use `IFS=',' read -ra ...` (an assignment prefix scoped to that one
command), not `local IFS=','; read -ra ...` as a separate statement — the latter leaves `IFS`
set to `,` for the rest of the function, silently breaking any later `"${array[*]}"` join (which
uses `IFS`'s first character as the separator) — e.g. printing `inherits from: reddit,news-en`
instead of `reddit news-en`. Caught during testing (see Verification).

If the new name collides with a bundled profile, print a one-line shadowing note and proceed —
don't refuse (refusing would require hardcoding the bundled-name set in `cmd_new`).

`cmd_new` needs no cycle check itself: a cycle can only be introduced by hand-editing
`parents.list` later (the new profile doesn't exist yet at validation time, so nothing can
already point back at it). `resolve_profile_chain`'s lazy detection at apply-time is the actual
guard.

## 8. `cmd_list` / `describe_profile_dir`

Shared helper `describe_profile_dir <dir>` prints a profile's sources/deny/allow summary line
plus a `from: <parents>` line if `parents.list` is non-empty; used for both the user-profiles
section and a second "Bundled profiles" section listing `$BUILTIN_PROFILES_DIR/*/`.

**Pitfall hit and fixed during testing:** `describe_profile_dir`'s original last statement was
`[[ "${#parents_arr[@]}" -gt 0 ]] && printf ...` — when a profile has no parents (the common
case), that condition is false, making the **function's own return status** 1 (a bash function
returns the exit status of its last-executed command). Unlike the `merge_profile_lists && ...`
case in §5, this function is called **bare** in a `for` loop (`describe_profile_dir "$dir"`, no
`||`/`if` guard) — and an unguarded bare command with nonzero status **does** trigger `set -e`,
silently killing the whole script mid-loop (confirmed by tracing with `bash -x`: execution
stopped right after printing the first bundled profile, with no error message, because `set -e`
exits silently — it's not an error path, it's `errexit` doing exactly what it's told). Fixed by
adding an explicit `return 0` as the function's actual last statement. General lesson: a
bare-called function whose last statement can be a legitimately-false `cond && action` under
`set -e` needs an explicit trailing `return 0` — the exemption for `&&`'s left side protects the
statement *itself* from killing the *function*, but does not protect the function's *caller* from
the function's resulting nonzero return status.

## Verification

No `hblock`/`shellcheck`/bats/CI coverage exists for this script. Because of the §6 reordering,
everything new is exercisable end-to-end via the real script, pointed at temp dirs, without root:

```bash
tmp="$(mktemp -d)"
export CURFEW_PROFILES_DIR="$tmp/profiles"
export CURFEW_BUILTIN_PROFILES_DIR="$tmp/builtin"
mkdir -p "$CURFEW_BUILTIN_PROFILES_DIR/reddit" "$CURFEW_BUILTIN_PROFILES_DIR/news-en"
echo reddit.com > "$CURFEW_BUILTIN_PROFILES_DIR/reddit/deny.list"
echo cnn.com > "$CURFEW_BUILTIN_PROFILES_DIR/news-en/deny.list"

./curfew --list                                    # shows both bundled profiles
./curfew --new work --from reddit,news-en           # exercises validation + parents.list write
cat "$CURFEW_PROFILES_DIR/work/parents.list"         # -> reddit\nnews-en
./curfew --list                                     # shows "from: reddit news-en" under work
./curfew --new work                                  # -> "already exists", exit 1
./curfew --new bad --from nope                       # -> unknown profile 'nope', exit 1

mkdir -p "$CURFEW_PROFILES_DIR/a" "$CURFEW_PROFILES_DIR/b"
printf 'b\n' > "$CURFEW_PROFILES_DIR/a/parents.list"
printf 'a\n' > "$CURFEW_PROFILES_DIR/b/parents.list"
touch "$CURFEW_PROFILES_DIR/a/deny.list" "$CURFEW_PROFILES_DIR/b/deny.list"
./curfew a --for 1m
# -> exit 1, "cycle detected in profile inheritance: a -> b -> a", no sudo prompt
```

All of the above was actually run during implementation (not just planned) — it's what caught
both pitfalls documented in §7 and §8.

The one thing this can't verify without real `hblock`/root: the actual `/etc/hosts` content
after a full apply (bundled profiles fetch correctly, merged `-S`/`-D`/`-A` temp files contain
the right domains, `/etc/hosts` ends up correct). That needs a machine with `hblock` installed —
a manual follow-up, not verified from this environment.

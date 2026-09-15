# Fish Shell Completion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give `curfew` fish-shell tab completion with feature parity to the existing bash
completion (`completions/curfew.bash`, added in commit `626bdfe`).

**Architecture:** A single `completions/curfew.fish` file registered via fish's `complete -c
curfew` builtin, using condition functions (`complete -n ...`) to detect argument position
(first word vs. after a profile vs. inside `--new`). Profile-name candidates come from a
`__curfew_profile_names` function that re-implements curfew's own profile lookup (user dir, then
bundled dir resolved via the `curfew` symlink on `$PATH`), matching the approach already used in
`completions/curfew.bash`. Tested with `fish -c 'complete -C "..."'`, which runs fish's real
completion engine non-interactively and prints matching candidates — the fish-native equivalent
of the `COMP_WORDS`/`COMPREPLY` harness used for the bash tests.

**Tech Stack:** fish (`complete`, `commandline -opc`), bash (test driver, matching
`tests/test_completion.bash`'s style — no test framework).

**Spec:** No separate spec doc — scope was agreed inline in conversation: match
`completions/curfew.bash`'s behavior exactly (profile names, `--list`/`--new`/`--help` as the
first word, `--for`/`--until` after a profile, `--from` after `curfew --new <name>`), tested
automatically, wired into `make install`/`make test`, documented in the README.

## Global Constraints

- No new runtime dependency beyond `fish` itself (already how the bash completion avoids
  depending on the optional `bash-completion` package for its core logic).
- Match `completions/curfew.bash`'s covered surface exactly — do not add candidates the bash
  version doesn't have (e.g. no completion for the free-form new-profile name or `--from`'s
  comma-separated values, same as bash).
- Follow the existing project style: no framework, no build step, plain-bash or plain-fish test
  scripts runnable directly.

---

## Fish completion mechanics the executor needs (verified interactively before writing this plan)

- `complete -c NAME -f` registered unconditionally disables fish's default filename-completion
  fallback for that command — needed once, up top, same intent as the bash script never
  suggesting filenames.
- `complete -C "curfew work "` (a full simulated command line, quoted) is how to query fish's
  completion engine from a script. Output is tab-separated `candidate<TAB>description` per line;
  `cut -f1` extracts just the candidate.
- **Long-option candidates (`-l foo`) only appear once the current token starts with a dash.**
  `complete -C "curfew "` (empty last token) will NOT show `--list`/`--new`/`--help` even though
  they're registered for that position — this matches fish's real interactive behavior (you don't
  see `--foo` suggested until you type `-`). `complete -C "curfew --"` shows them. Tests must
  query with a `--` (or a partial like `--f`) prefix when asserting flag candidates, not with an
  empty string. Candidates from `-a '(...)'` (like profile names) DO show with an empty token.
- `commandline -opc` inside a condition function returns the already-committed words before the
  cursor, **excluding the word currently being typed**. For `curfew --new foo` with no trailing
  space (still typing `foo`), `-opc` is `(curfew --new)` (count 2). For `curfew --new foo ` (past
  a trailing space, completing the next word), `-opc` is `(curfew --new foo)` (count 3). The
  `--from` condition below relies on this to fire only in the latter case.

---

## Task 1: `completions/curfew.fish` + automated tests

**Files:**
- Create: `completions/curfew.fish`
- Create: `tests/test_completion_fish.sh`
- Modify: none yet (Makefile/README wiring is Task 2)

**Interfaces:**
- Produces: `completions/curfew.fish`, auto-loadable by fish from
  `~/.config/fish/completions/curfew.fish` (Task 2 installs it there) or by `source`ing it
  directly. Registers completions for the `curfew` command via `complete -c curfew`.
- Consumes: nothing from other tasks. Mirrors (does not import) the profile-lookup logic in
  `completions/curfew.bash` and in `curfew` itself (`curfew:37`, `curfew:42-51`).

- [ ] **Step 1: Write the failing test file**

Create `tests/test_completion_fish.sh` with this exact content:

```bash
#!/usr/bin/env bash
# Plain-bash driver for fish completions — no test framework, mirrors
# tests/test_completion.bash's style. Requires fish on PATH. Run directly:
#   bash tests/test_completion_fish.sh

set -uo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
COMPLETION_FILE="$SCRIPT_DIR/../completions/curfew.fish"

if ! command -v fish >/dev/null 2>&1; then
  echo "SKIP: fish not installed" >&2
  exit 0
fi

pass_count=0
fail_count=0

FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/curfew-fish-completion-test.XXXXXX")"
trap 'rm -rf "$FIXTURE_DIR"' EXIT

mkdir -p "$FIXTURE_DIR/user-profiles/work"
mkdir -p "$FIXTURE_DIR/user-profiles/focus"
mkdir -p "$FIXTURE_DIR/builtin-profiles/games"
mkdir -p "$FIXTURE_DIR/builtin-profiles/gambling"
mkdir -p "$FIXTURE_DIR/builtin-profiles/news"

export CURFEW_PROFILES_DIR="$FIXTURE_DIR/user-profiles"
export CURFEW_BUILTIN_PROFILES_DIR="$FIXTURE_DIR/builtin-profiles"

# Tests run against a throwaway command name (not "curfew") so they don't
# depend on a real curfew being installed on PATH.
TEST_CMD=curfewtest
COMPLETION_UNDER_TEST="$FIXTURE_DIR/completion.fish"
sed "s/-c curfew /-c $TEST_CMD /g" "$COMPLETION_FILE" >"$COMPLETION_UNDER_TEST"

# Populates the global CANDIDATES array with the candidate names (first
# tab-separated column) fish offers for a given simulated command line.
# Usage: complete_for "curfewtest wor"
complete_for() {
  mapfile -t CANDIDATES < <(fish -c "source '$COMPLETION_UNDER_TEST'; complete -C '$1'" | cut -f1)
}

assert_contains() {
  local desc="$1" needle="$2"
  local item
  for item in "${CANDIDATES[@]}"; do
    [[ "$item" == "$needle" ]] && { pass_count=$((pass_count + 1)); return; }
  done
  fail_count=$((fail_count + 1))
  echo "FAIL: $desc — expected '$needle' in [${CANDIDATES[*]}]"
}

assert_not_contains() {
  local desc="$1" needle="$2"
  local item
  for item in "${CANDIDATES[@]}"; do
    if [[ "$item" == "$needle" ]]; then
      fail_count=$((fail_count + 1))
      echo "FAIL: $desc — did not expect '$needle' in [${CANDIDATES[*]}]"
      return
    fi
  done
  pass_count=$((pass_count + 1))
}

assert_empty() {
  local desc="$1"
  if [[ "${#CANDIDATES[@]}" -eq 0 ]]; then
    pass_count=$((pass_count + 1))
  else
    fail_count=$((fail_count + 1))
    echo "FAIL: $desc — expected no completions, got [${CANDIDATES[*]}]"
  fi
}

# -- tests -----------------------------------------------------------------

complete_for "$TEST_CMD "
assert_contains "first word offers user profiles" "work"
assert_contains "first word offers builtin profiles" "games"

complete_for "$TEST_CMD ga"
assert_contains "prefix 'ga' matches games" "games"
assert_contains "prefix 'ga' matches gambling" "gambling"
assert_not_contains "prefix 'ga' excludes news" "news"
assert_not_contains "prefix 'ga' excludes work" "work"

complete_for "$TEST_CMD --"
assert_contains "'--' offers --list" "--list"
assert_contains "'--' offers --new" "--new"
assert_contains "'--' offers --help" "--help"

complete_for "$TEST_CMD work --"
assert_contains "after profile, '--' offers --for" "--for"
assert_contains "after profile, '--' offers --until" "--until"

complete_for "$TEST_CMD work --f"
assert_contains "after profile, '--f' matches --for" "--for"

complete_for "$TEST_CMD work --for --"
assert_empty "no more flag suggestions right after --for"

complete_for "$TEST_CMD work --for 2h"
assert_empty "no suggestions for the duration value"

complete_for "$TEST_CMD --new foo --"
assert_contains "after --new <name>, offers --from" "--from"

complete_for "$TEST_CMD --new foo"
assert_empty "no suggestions while still typing the new name"

echo
echo "$pass_count passed, $fail_count failed"
[[ "$fail_count" -eq 0 ]]
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/test_completion_fish.sh`
Expected: fails with `fish: ... completions/curfew.fish: No such file or directory` (or similar
"file not found" from `sed`), not a silent pass. If fish isn't installed in the environment,
install it first (e.g. `sudo apt-get install -y fish` on Debian/Ubuntu) — the test intentionally
skips with exit 0 when fish is absent, which would hide this RED step, so confirm fish is present
before treating a `SKIP` as the expected failure.

- [ ] **Step 3: Write `completions/curfew.fish`**

Create `completions/curfew.fish` with this exact content:

```fish
# fish completion for curfew — fish auto-loads this from
# ~/.config/fish/completions/curfew.fish (see `make install`), no sourcing
# needed.

# Lists profile names from $CURFEW_PROFILES_DIR and the bundled profiles
# dir, same lookup order as curfew itself (user profiles, then bundled).
# When CURFEW_BUILTIN_PROFILES_DIR isn't set, resolves it relative to
# wherever `curfew` itself resolves to on PATH (following symlinks),
# mirroring the script's own SCRIPT_DIR logic so completion works for an
# installed symlink.
function __curfew_profile_names
    set -l profiles_dir $CURFEW_PROFILES_DIR
    if test -z "$profiles_dir"
        set profiles_dir $HOME/.config/curfew/profiles
    end

    set -l builtin_dir $CURFEW_BUILTIN_PROFILES_DIR
    if test -z "$builtin_dir"
        set -l script (command -v curfew)
        if test -n "$script"
            while test -L "$script"
                set -l dir (cd (dirname "$script"); and pwd)
                set script (readlink "$script")
                if not string match -q '/*' -- "$script"
                    set script "$dir/$script"
                end
            end
            set builtin_dir (dirname "$script")/profiles
        end
    end

    for d in $profiles_dir/*/ $builtin_dir/*/
        if test -d "$d"
            basename "$d"
        end
    end | sort -u
end

function __curfew_first_arg
    set -l cmd (commandline -opc)
    test (count $cmd) -eq 1
end

function __curfew_second_arg_is_new
    set -l cmd (commandline -opc)
    test (count $cmd) -ge 2; and test "$cmd[2]" = --new
end

# curfew --new <name> [--from a,b,c] — only --from is completable; the new
# name and the --from list itself are free-form.
function __curfew_from_flag_position
    __curfew_second_arg_is_new; and test (count (commandline -opc)) -eq 3
end

function __curfew_prev_is_time_flag
    set -l cmd (commandline -opc)
    test (count $cmd) -ge 1; and contains -- "$cmd[-1]" --for --until
end

# curfew <profile> [user] --for <duration> | --until <time>
function __curfew_after_profile
    set -l cmd (commandline -opc)
    test (count $cmd) -ge 2
    and not contains -- "$cmd[2]" --list --new --help
    and not __curfew_prev_is_time_flag
end

complete -c curfew -f

complete -c curfew -n __curfew_first_arg -a '(__curfew_profile_names)' -d profile
complete -c curfew -n __curfew_first_arg -l list -d 'List available profiles'
complete -c curfew -n __curfew_first_arg -l new -d 'Scaffold a new profile'
complete -c curfew -n __curfew_first_arg -l help -d 'Show help'

complete -c curfew -n __curfew_from_flag_position -l from -d 'Comma-separated parent profiles'

complete -c curfew -n __curfew_after_profile -l for -d 'Apply and lock for a duration'
complete -c curfew -n __curfew_after_profile -l until -d 'Apply and lock until a time'
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/test_completion_fish.sh`
Expected: `16 passed, 0 failed` (16 `assert_*` calls above), exit code 0.

- [ ] **Step 5: Sanity-check PATH-resolution fallback for real installs**

The fixture tests always set `CURFEW_BUILTIN_PROFILES_DIR` directly, which skips the
`command -v curfew` symlink-following branch in `__curfew_profile_names`. Verify that branch
works too, the same way it was checked for the bash version:

```bash
tmpbin="$(mktemp -d)"
ln -s "$PWD/curfew" "$tmpbin/curfew"
fish -c '
  set -x PATH '"$tmpbin"' $PATH
  set -e CURFEW_PROFILES_DIR
  set -e CURFEW_BUILTIN_PROFILES_DIR
  source completions/curfew.fish
  __curfew_profile_names
'
rm -rf "$tmpbin"
```

Expected: prints the bundled profile names (`bypass`, `entertainment`, `forums-chat`, `gambling`,
`games`, `memes`, `news`, `porn`, `reddit`, `shopping`, `social-media`, `sports`, `video`).

- [ ] **Step 6: Commit**

```bash
git add completions/curfew.fish tests/test_completion_fish.sh
git commit -m "Add fish tab-completion, matching the bash completion's coverage"
```

---

## Task 2: Wire into `make install` / `make test`, document in README

**Files:**
- Modify: `Makefile`
- Modify: `README.md`

**Interfaces:**
- Consumes: `completions/curfew.fish` from Task 1 (must exist and be committed first).
- Produces: `make install` symlinks it into fish's per-user completions directory; `make test`
  runs both completion test scripts.

- [ ] **Step 1: Add a `FISHCOMPDIR` variable and wire it into `install`/`uninstall`**

Fish auto-loads completions from `~/.config/fish/completions/<cmd>.fish` unconditionally (unlike
bash, this doesn't depend on an optional package being installed), so — unlike `BASHCOMPDIR` —
this path is not `$(PREFIX)`-relative; keep it a separate, directly overridable variable.

Edit `Makefile`. Current relevant section (after Task 1's bash-completion commit) reads:

```makefile
PREFIX      ?= $(HOME)/.local
BINDIR      ?= $(PREFIX)/bin
CONFIGDIR   ?= $(HOME)/.config/curfew
BASHCOMPDIR ?= $(PREFIX)/share/bash-completion/completions

SCRIPT := $(CURDIR)/curfew
BASH_COMPLETION_SCRIPT := $(CURDIR)/completions/curfew.bash

.PHONY: install uninstall purge test

install:
	mkdir -p $(BINDIR)
	ln -sf $(SCRIPT) $(BINDIR)/curfew
	mkdir -p $(BASHCOMPDIR)
	ln -sf $(BASH_COMPLETION_SCRIPT) $(BASHCOMPDIR)/curfew

uninstall:
	rm -f $(BINDIR)/curfew
	rm -f $(BASHCOMPDIR)/curfew

purge: uninstall
	rm -rf $(CONFIGDIR)

test:
	bash tests/test_completion.bash
```

Replace it with:

```makefile
PREFIX      ?= $(HOME)/.local
BINDIR      ?= $(PREFIX)/bin
CONFIGDIR   ?= $(HOME)/.config/curfew
BASHCOMPDIR ?= $(PREFIX)/share/bash-completion/completions
FISHCOMPDIR ?= $(HOME)/.config/fish/completions

SCRIPT := $(CURDIR)/curfew
BASH_COMPLETION_SCRIPT := $(CURDIR)/completions/curfew.bash
FISH_COMPLETION_SCRIPT := $(CURDIR)/completions/curfew.fish

.PHONY: install uninstall purge test

install:
	mkdir -p $(BINDIR)
	ln -sf $(SCRIPT) $(BINDIR)/curfew
	mkdir -p $(BASHCOMPDIR)
	ln -sf $(BASH_COMPLETION_SCRIPT) $(BASHCOMPDIR)/curfew
	mkdir -p $(FISHCOMPDIR)
	ln -sf $(FISH_COMPLETION_SCRIPT) $(FISHCOMPDIR)/curfew.fish

uninstall:
	rm -f $(BINDIR)/curfew
	rm -f $(BASHCOMPDIR)/curfew
	rm -f $(FISHCOMPDIR)/curfew.fish

purge: uninstall
	rm -rf $(CONFIGDIR)

test:
	bash tests/test_completion.bash
	bash tests/test_completion_fish.sh
```

- [ ] **Step 2: Verify `make install`/`make uninstall` by replaying them against a scratch HOME**

`FISHCOMPDIR` is keyed off `$(HOME)` directly (not `$(PREFIX)`), so overriding `PREFIX` alone
(as used for the bash-completion scratch-test) won't relocate it — override both:

```bash
tmphome="$(mktemp -d)"
PREFIX="$tmphome/.local" FISHCOMPDIR="$tmphome/.config/fish/completions" make install
ls -la "$tmphome/.config/fish/completions"
readlink -f "$tmphome/.config/fish/completions/curfew.fish"
PREFIX="$tmphome/.local" FISHCOMPDIR="$tmphome/.config/fish/completions" make uninstall
ls "$tmphome/.config/fish/completions"   # should be empty
rm -rf "$tmphome"
```

Expected: `curfew.fish -> <repo>/completions/curfew.fish` after install; directory empty after
uninstall.

- [ ] **Step 3: Run `make test`**

Run: `make test`
Expected: both `tests/test_completion.bash` and `tests/test_completion_fish.sh` report `N passed,
0 failed` with a combined exit code of 0.

- [ ] **Step 4: Document in README**

Edit `README.md`. Find the `### Shell completion (bash)` section added in commit `626bdfe` (it
currently ends with the sentence starting "It completes profile names…"). Add a new section right
after it:

```markdown
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
```

- [ ] **Step 5: Commit**

```bash
git add Makefile README.md
git commit -m "Wire fish completion into make install and document it"
```

---

## Execution notes

- This plan was written and its fish-completion mechanics (Step "Fish completion mechanics"
  above) verified interactively in the same session, against a scratch fixture — not against the
  files this plan creates. Task 1 still starts from a failing test per TDD; the exploration was
  thrown away before Task 1 Step 1.
- After Task 2, the user tests fish completion manually (`curfew <TAB>` etc., same as they did for
  bash) before this branch's work is committed further or pushed — do not push until they
  confirm.

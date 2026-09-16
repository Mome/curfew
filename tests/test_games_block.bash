#!/usr/bin/env bash
# Plain-bash tests for native game blocking (`block-games` profile marker and
# `curfew --detect-games`) — no test framework, mirrors test_apply.bash. Runs
# the real script as a subprocess against a fixture filesystem (desktop
# entries, a Steam library, Flatpak/Snap exports) via the CURFEW_* seams, with
# `sudo`/`nosudo`/`hblock`/`snap` replaced by fixture scripts on PATH. Run:
#   bash tests/test_games_block.bash

set -uo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
CURFEW="$SCRIPT_DIR/../curfew"

pass_count=0
fail_count=0

pass() { pass_count=$((pass_count + 1)); }
fail() { fail_count=$((fail_count + 1)); echo "FAIL: $*"; }

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  [[ "$expected" == "$actual" ]] && pass || fail "$desc — expected '$expected', got '$actual'"
}

assert_success() { [[ "$2" -eq 0 ]] && pass || fail "$1 — expected exit 0, got $2"; }
assert_failure() { [[ "$2" -ne 0 ]] && pass || fail "$1 — expected a nonzero exit, got 0"; }

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  [[ "$haystack" == *"$needle"* ]] && pass || fail "$desc — expected to find '$needle' in:"$'\n'"$haystack"
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  [[ "$haystack" != *"$needle"* ]] && pass || fail "$desc — did not expect '$needle' in:"$'\n'"$haystack"
}

# Asserts some single line of $haystack contains both $word and $needle.
assert_line_with() {
  local desc="$1" word="$2" needle="$3" haystack="$4"
  if grep -F -- "$needle" <<<"$haystack" | grep -q -w -- "$word"; then
    pass
  else
    fail "$desc — expected a '$word' line mentioning '$needle' in:"$'\n'"$haystack"
  fi
}

assert_before() {
  local desc="$1" first="$2" second="$3" log="$4"
  local first_line second_line
  first_line="$(grep -n -F -- "$first" <<<"$log" | head -1 | cut -d: -f1)"
  second_line="$(grep -n -F -- "$second" <<<"$log" | head -1 | cut -d: -f1)"
  if [[ -n "$first_line" && -n "$second_line" && "$first_line" -lt "$second_line" ]]; then
    pass
  else
    fail "$desc — expected '$first' before '$second' in:"$'\n'"$log"
  fi
}

mode_of() { stat -c '%a' "$1"; }

# -- fixtures ----------------------------------------------------------------

FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/curfew-games-test.XXXXXX")"
trap 'chmod -R u+rwx "$FIXTURE_DIR" 2>/dev/null; rm -rf "$FIXTURE_DIR"' EXIT
F="$FIXTURE_DIR"
export FIXTURE_DIR
export MOCKLOG="$F/mocklog"

mkdir -p "$F/bin" "$F/restore-bin" "$F/builtin-profiles" \
  "$F/profiles/plain" "$F/profiles/gamer" "$F/profiles/child"
: > "$F/profiles/plain/deny.list"
: > "$F/profiles/gamer/deny.list"
: > "$F/profiles/gamer/block-games"
echo gamer > "$F/profiles/child/parents.list"

# Native games. The quoted Exec path with a space exercises Exec= quoting.
mkdir -p "$F/games/My Games" "$F/apps"
SUPERTUX="$F/games/My Games/supertux"
printf '#!/bin/sh\n' > "$SUPERTUX"
chmod 755 "$SUPERTUX"
printf '#!/bin/sh\n' > "$F/games/editor"
chmod 755 "$F/games/editor"
printf '#!/bin/sh\n' > "$F/games/hiddengame"
chmod 755 "$F/games/hiddengame"

cat > "$F/apps/supertux.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=SuperTux
Categories=Game;ArcadeGame;
Exec="$SUPERTUX" %U

[Desktop Action Editor]
Exec=$F/games/editor
EOF

cat > "$F/apps/editor.desktop" <<EOF
[Desktop Entry]
Name=Editor
Categories=Development;
Exec=$F/games/editor
EOF

cat > "$F/apps/steamgame.desktop" <<EOF
[Desktop Entry]
Name=Some Steam Game
Categories=Game;
Exec=steam steam://rungameid/413150
EOF

cat > "$F/apps/pygame.desktop" <<EOF
[Desktop Entry]
Name=PyGame Thing
Categories=Game;
Exec=python3 $F/games/thing.py
EOF

cat > "$F/apps/truegame.desktop" <<EOF
[Desktop Entry]
Name=Totally A Game
Categories=Game;
Exec=/usr/bin/true
EOF

# An innocently named binary that is really a symlink to a launcher outside
# any system path (e.g. /opt/wine/bin/wine).
mkdir -p "$F/opt-wine/bin"
printf '#!/bin/sh\n' > "$F/opt-wine/bin/wine"
chmod 755 "$F/opt-wine/bin/wine"
ln -s "$F/opt-wine/bin/wine" "$F/games/retro"
cat > "$F/apps/retro.desktop" <<EOF
[Desktop Entry]
Name=Retro
Categories=Game;
Exec=$F/games/retro game.exe
EOF

cat > "$F/apps/hidden.desktop" <<EOF
[Desktop Entry]
Name=Hidden
Categories=Game;
Hidden=true
Exec=$F/games/hiddengame
EOF

# Flatpak export + its deploy dir.
mkdir -p "$F/flatpak/exports/share/applications" "$F/flatpak/app/com.example.Chess"
chmod 755 "$F/flatpak/app/com.example.Chess"
CHESS_DIR="$F/flatpak/app/com.example.Chess"
cat > "$F/flatpak/exports/share/applications/com.example.Chess.desktop" <<EOF
[Desktop Entry]
Name=Chess
Categories=Game;BoardGame;
Exec=/usr/bin/flatpak run --branch=stable com.example.Chess
X-Flatpak=com.example.Chess
EOF

# Snap export.
mkdir -p "$F/snapd/desktop/applications"
cat > "$F/snapd/desktop/applications/mari0_mari0.desktop" <<EOF
[Desktop Entry]
Name=Mari0
Categories=Game;
Exec=env BAMF_DESKTOP_FILE_HINT=/var/lib/snapd/desktop/applications/mari0_mari0.desktop /snap/bin/mari0 %U
X-SnapInstanceName=mari0
EOF

DESKTOP_DIRS="$F/apps:$F/flatpak/exports/share/applications:$F/snapd/desktop/applications"

# Steam: a default root with a second library (current nested VDF schema).
mkdir -p "$F/steam-root/steamapps/common/Stardew Valley" \
  "$F/steam-root/steamapps/common/SteamLinuxRuntime_sniper" \
  "$F/steam-lib2/steamapps/common/Portal 2"
STARDEW="$F/steam-root/steamapps/common/Stardew Valley"
SNIPER="$F/steam-root/steamapps/common/SteamLinuxRuntime_sniper"
PORTAL="$F/steam-lib2/steamapps/common/Portal 2"
chmod 755 "$STARDEW" "$SNIPER" "$PORTAL"

cat > "$F/steam-root/steamapps/libraryfolders.vdf" <<EOF
"libraryfolders"
{
	"0"
	{
		"path"		"$F/steam-root"
		"label"		""
	}
	"1"
	{
		"path"		"$F/steam-lib2"
		"label"		""
	}
}
EOF

write_acf() {
  cat > "$1" <<EOF
"AppState"
{
	"appid"		"$2"
	"name"		"$3"
	"installdir"		"$4"
}
EOF
}
write_acf "$F/steam-root/steamapps/appmanifest_413150.acf" 413150 "Stardew Valley" "Stardew Valley"
write_acf "$F/steam-root/steamapps/appmanifest_1628350.acf" 1628350 "Steam Linux Runtime 3.0 (sniper)" "SteamLinuxRuntime_sniper"
write_acf "$F/steam-lib2/steamapps/appmanifest_620.acf" 620 "Portal 2" "Portal 2"
mkdir -p "$F/steam-lib2/steamapps/common/Proton 9.0"
PROTON="$F/steam-lib2/steamapps/common/Proton 9.0"
write_acf "$F/steam-lib2/steamapps/appmanifest_2805730.acf" 2805730 "Proton 9.0" "Proton 9.0"

# A Steam root using the older flat VDF schema.
mkdir -p "$F/steam-old/steamapps" "$F/steam-lib3/steamapps/common/Terraria"
cat > "$F/steam-old/steamapps/libraryfolders.vdf" <<EOF
"LibraryFolders"
{
	"TimeNextStatsReport"		"1700000000"
	"1"		"$F/steam-lib3"
}
EOF
write_acf "$F/steam-lib3/steamapps/appmanifest_105600.acf" 105600 "Terraria" "Terraria"

OWNER="$(stat -c '%u:%g' "$SUPERTUX")"

# Fake sudo: logs every call. Only runs a command for real when it's a
# harmless file op (or a fixture fake) whose every absolute-path argument is
# inside the fixture — so /etc/hosts, systemd units, and real binaries are
# never touched. chown is log-only (a non-root test can't chown to root).
cat > "$F/bin/sudo" <<'EOF'
#!/usr/bin/env bash
echo "sudo $*" >> "$MOCKLOG"
drain() { [[ "$1" == "tee" ]] && cat >/dev/null; }
if [[ -n "${SUDO_FAIL_MATCH:-}" && "$*" == *"$SUDO_FAIL_MATCH"* ]]; then
  drain "$1"; exit 1
fi
# Succeeds without doing anything, like chmod on a filesystem that ignores
# Unix permissions (NTFS, exFAT).
if [[ -n "${SUDO_NOOP_MATCH:-}" && "$*" == *"$SUDO_NOOP_MATCH"* ]]; then
  drain "$1"; exit 0
fi
case "$1" in
  chmod | tee | cat | test | rm | mkdir | stat | realpath) ;;
  chown) exit 0 ;;
  *)
    if [[ "$(command -v "$1")" == "$FIXTURE_DIR"/bin/* ]]; then exec "$@"; fi
    drain "$1"; exit 0
    ;;
esac
for arg in "${@:2}"; do
  if [[ "$arg" == /* && "$arg" != "$FIXTURE_DIR"/* ]]; then
    drain "$1"
    [[ "$1" == "test" ]] && exit 1
    exit 0
  fi
done
exec "$@"
EOF

cat > "$F/bin/nosudo" <<'EOF'
#!/usr/bin/env bash
echo "nosudo $*" >> "$MOCKLOG"
echo "$(id -un): sudo restricted until 2026-09-15 18:00 (5m from now)"
EOF

cat > "$F/bin/hblock" <<'EOF'
#!/usr/bin/env bash
echo "hblock $*" >> "$MOCKLOG"
EOF

cat > "$F/bin/snap" <<'EOF'
#!/usr/bin/env bash
echo "snap $*" >> "$MOCKLOG"
EOF

# Resolvable `steam`, so only the launcher rule (not a failed lookup) can
# keep steamgame.desktop from being blocked. A symlink to a differently named
# script, as distro packages often install it, so the rule must look at the
# name the entry uses, not just the resolved file.
mkdir -p "$F/launchers"
printf '#!/bin/sh\n' > "$F/launchers/steam-wrapper.sh"
chmod +x "$F/launchers/steam-wrapper.sh"
ln -s "$F/launchers/steam-wrapper.sh" "$F/bin/steam"

# Used only when executing the generated restore script directly.
for c in systemctl cp rm; do
  printf '#!/bin/sh\necho "restore-%s $*" >> "$MOCKLOG"\n' "$c" > "$F/restore-bin/$c"
done
chmod +x "$F"/bin/* "$F"/restore-bin/*

STATE="$F/state"

run_curfew() {
  : > "$MOCKLOG"
  PATH="$F/bin:$PATH" \
    CURFEW_PROFILES_DIR="$F/profiles" \
    CURFEW_BUILTIN_PROFILES_DIR="$F/builtin-profiles" \
    CURFEW_STATE_DIR="$STATE" \
    CURFEW_DESKTOP_DIRS="$DESKTOP_DIRS" \
    CURFEW_STEAM_ROOTS="${STEAM_ROOTS_OVERRIDE:-$F/steam-root}" \
    bash "$CURFEW" "$@"
}

reset_fixture() {
  chmod 755 "$SUPERTUX" "$STARDEW" "$SNIPER" "$PORTAL" "$CHESS_DIR" "$F/games/editor" "$F/games/hiddengame"
  rm -rf "$STATE"
}

# -- --detect-games ------------------------------------------------------------

output="$(run_curfew --detect-games 2>&1)"
status=$?
assert_success "--detect-games exits 0" "$status"
assert_line_with "detect: native game from .desktop" block "$SUPERTUX" "$output"
assert_line_with "detect: flatpak game deploy dir" block "$CHESS_DIR" "$output"
assert_line_with "detect: snap game" block "mari0" "$output"
assert_line_with "detect: steam game in default library" block "$STARDEW" "$output"
assert_line_with "detect: steam game in secondary library" block "$PORTAL" "$output"
assert_line_with "detect: steam runtime is skipped" skip "Steam Linux Runtime" "$output"
assert_line_with "detect: proton is skipped" skip "Proton 9.0" "$output"
assert_not_contains "detect: steam launcher script is never blocked" "steam-wrapper.sh" "$output"
assert_line_with "detect: steam:// launcher entry is skipped" skip "steamgame.desktop" "$output"
assert_line_with "detect: interpreter entry is skipped" skip "pygame.desktop" "$output"
assert_line_with "detect: entry resolving to a launcher is skipped" skip "retro.desktop" "$output"
assert_line_with "detect: system binary with unrelated name is skipped" skip "truegame.desktop" "$output"
assert_not_contains "detect: nothing from truegame.desktop is blocked" "block  /usr/bin/" "$output"
assert_not_contains "detect: non-game apps are ignored" "editor" "$output"
assert_not_contains "detect: Hidden=true entries are ignored" "hiddengame" "$output"
assert_eq "detect: calls no sudo/snap at all" "" "$(cat "$MOCKLOG")"
assert_eq "detect: changes no permissions" "755" "$(mode_of "$SUPERTUX")"

output="$(STEAM_ROOTS_OVERRIDE="$F/steam-old" run_curfew --detect-games 2>&1)"
assert_line_with "detect: old flat libraryfolders.vdf schema" block "$F/steam-lib3/steamapps/common/Terraria" "$output"

# -- apply without the marker ------------------------------------------------

reset_fixture
output="$(run_curfew plain --for 5m 2>&1)"
status=$?
log="$(cat "$MOCKLOG")"
assert_success "no marker: apply exits 0" "$status"
assert_not_contains "no marker: nothing is locked" "chmod 000" "$log"
assert_not_contains "no marker: no snap disabled" "snap disable" "$log"
[[ -e "$STATE/apps.bak" ]] && fail "no marker: apps.bak must not exist" || pass

# -- apply with the marker ---------------------------------------------------

reset_fixture
output="$(run_curfew gamer --for 5m 2>&1)"
status=$?
log="$(cat "$MOCKLOG")"
manifest="$(cat "$STATE/apps.bak" 2>/dev/null)"
assert_success "marker: apply exits 0" "$status"
assert_contains "marker: manifest records native game" "perm $OWNER 755 $SUPERTUX" "$manifest"
assert_contains "marker: manifest records steam game" "perm $OWNER 755 $STARDEW" "$manifest"
assert_contains "marker: manifest records secondary-library game" "perm $OWNER 755 $PORTAL" "$manifest"
assert_contains "marker: manifest records flatpak game" "perm $OWNER 755 $CHESS_DIR" "$manifest"
assert_contains "marker: manifest records snap game" "snap mari0" "$manifest"
assert_not_contains "marker: runtime not recorded" "$SNIPER" "$manifest"
assert_not_contains "marker: system binary not recorded" "/usr/bin/true" "$manifest"
assert_eq "marker: native game locked" "0" "$(mode_of "$SUPERTUX")"
assert_eq "marker: steam game locked" "0" "$(mode_of "$STARDEW")"
assert_eq "marker: flatpak game locked" "0" "$(mode_of "$CHESS_DIR")"
assert_eq "marker: runtime untouched" "755" "$(mode_of "$SNIPER")"
assert_contains "marker: ownership taken so the user can't chmod it back" "sudo chown root:root $SUPERTUX" "$log"
assert_before "marker: entry recorded before it is locked" "tee -a $STATE/apps.bak" "chmod 000" "$log"
assert_before "marker: games locked before sudo is revoked" "chmod 000" "nosudo restrict" "$log"
assert_before "marker: snap disabled before sudo is revoked" "snap disable mari0" "nosudo restrict" "$log"

# -- the generated restore script undoes it ------------------------------------

restore_script="$STATE/restore-curfew.sh"
script_body="$(cat "$restore_script" 2>/dev/null)"
assert_contains "restore script replays apps.bak" "$STATE/apps.bak" "$script_body"
: > "$MOCKLOG"
PATH="$F/restore-bin:$F/bin:$PATH" sh "$restore_script" 2>&1
log="$(cat "$MOCKLOG")"
assert_eq "restore script: native game mode restored" "755" "$(mode_of "$SUPERTUX")"
assert_eq "restore script: steam game (path with space) restored" "755" "$(mode_of "$STARDEW")"
assert_eq "restore script: flatpak game restored" "755" "$(mode_of "$CHESS_DIR")"
assert_contains "restore script: snap re-enabled" "snap enable mari0" "$log"

# -- inheritance ---------------------------------------------------------------

reset_fixture
output="$(run_curfew child --for 5m 2>&1)"
assert_contains "inherited marker blocks games too" "$SUPERTUX" "$(cat "$STATE/apps.bak" 2>/dev/null)"

# -- rollback when a later block fails -----------------------------------------

reset_fixture
output="$(SUDO_FAIL_MATCH="chmod 000 $PORTAL" run_curfew gamer --for 5m 2>&1)"
status=$?
log="$(cat "$MOCKLOG")"
assert_failure "rollback: failed block exits nonzero" "$status"
assert_not_contains "rollback: no unbound variable" "unbound variable" "$output"
assert_eq "rollback: earlier native lock undone" "755" "$(mode_of "$SUPERTUX")"
assert_eq "rollback: earlier steam lock undone" "755" "$(mode_of "$STARDEW")"
assert_contains "rollback: snap re-enabled" "snap enable mari0" "$log"
assert_not_contains "rollback: sudo is never revoked" "nosudo restrict" "$log"
[[ -e "$STATE/apps.bak" ]] && fail "rollback: apps.bak must be removed" || pass

# -- --list ------------------------------------------------------------------

reset_fixture
output="$(run_curfew --list 2>&1)"
assert_contains "list marks profiles with block-games" "games-block" "$(grep -E '^  gamer ' <<<"$output")"
assert_not_contains "list doesn't mark profiles without it" "games-block" "$(grep -E '^  plain ' <<<"$output")"

# -- a lock that silently didn't take is reported ----------------------------

reset_fixture
output="$(SUDO_NOOP_MATCH="chmod 000 $PORTAL" run_curfew gamer --for 5m 2>&1)"
status=$?
assert_success "ignored chmod: apply still completes" "$status"
assert_line_with "ignored chmod: warns that the game is not locked" warning "$PORTAL" "$output"
assert_not_contains "ignored chmod: games that did lock get no warning" "warning: $STARDEW" "$output"

# -- restore refuses paths swapped for symlinks during the curfew -------------
# Runs last: it rearranges the fixture. The restore script runs as root over
# paths inside user-writable directories, so a user must not be able to point
# a recorded path at some other file and have root chown/chmod that instead.

reset_fixture
run_curfew gamer --for 5m >/dev/null 2>&1
printf 'secret\n' > "$F/victim"
chmod 600 "$F/victim"
mv "$SUPERTUX" "$SUPERTUX.moved"
ln -s "$F/victim" "$SUPERTUX"
mkdir -p "$F/decoy/Stardew Valley"
chmod 700 "$F/decoy/Stardew Valley"
mv "$STARDEW" "$STARDEW.moved"
mv "$F/steam-root/steamapps/common" "$F/steam-root/steamapps/common.moved"
ln -s "$F/decoy" "$F/steam-root/steamapps/common"
: > "$MOCKLOG"
PATH="$F/restore-bin:$F/bin:$PATH" sh "$STATE/restore-curfew.sh" >/dev/null 2>&1
assert_eq "swap: symlinked final component is not followed" "600" "$(mode_of "$F/victim")"
assert_eq "swap: symlinked parent directory is not followed" "700" "$(mode_of "$F/decoy/Stardew Valley")"
assert_eq "swap: untouched entries are still restored" "755" "$(mode_of "$CHESS_DIR")"

echo
echo "$pass_count passed, $fail_count failed"
[[ "$fail_count" -eq 0 ]]

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

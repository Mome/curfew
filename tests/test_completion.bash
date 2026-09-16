#!/usr/bin/env bash
# Plain-bash tests for completions/curfew.bash — no test framework, mirrors
# the rest of the project's "no build step" approach. Run directly:
#   bash tests/test_completion.bash

set -uo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
COMPLETION_FILE="$SCRIPT_DIR/../completions/curfew.bash"

pass_count=0
fail_count=0

# Sets COMP_WORDS/COMP_CWORD as bash's completion machinery would, then
# invokes the completion function and captures COMPREPLY.
# Usage: complete_at <cword> word0 word1 ...
complete_at() {
  local cword="$1"
  shift
  COMP_WORDS=("$@")
  COMP_CWORD="$cword"
  COMPREPLY=()
  _curfew
}

assert_contains() {
  local desc="$1" needle="$2"
  shift 2
  local -a haystack=("$@")
  local item
  for item in "${haystack[@]}"; do
    [[ "$item" == "$needle" ]] && { pass_count=$((pass_count + 1)); return; }
  done
  fail_count=$((fail_count + 1))
  echo "FAIL: $desc — expected '$needle' in [${haystack[*]}]"
}

assert_not_contains() {
  local desc="$1" needle="$2"
  shift 2
  local -a haystack=("$@")
  local item
  for item in "${haystack[@]}"; do
    if [[ "$item" == "$needle" ]]; then
      fail_count=$((fail_count + 1))
      echo "FAIL: $desc — did not expect '$needle' in [${haystack[*]}]"
      return
    fi
  done
  pass_count=$((pass_count + 1))
}

assert_empty() {
  local desc="$1"
  shift
  local -a haystack=("$@")
  if [[ "${#haystack[@]}" -eq 0 ]]; then
    pass_count=$((pass_count + 1))
  else
    fail_count=$((fail_count + 1))
    echo "FAIL: $desc — expected no completions, got [${haystack[*]}]"
  fi
}

# -- fixtures ----------------------------------------------------------------

FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/curfew-completion-test.XXXXXX")"
trap 'rm -rf "$FIXTURE_DIR"' EXIT

mkdir -p "$FIXTURE_DIR/user-profiles/work"
mkdir -p "$FIXTURE_DIR/user-profiles/focus"
mkdir -p "$FIXTURE_DIR/builtin-profiles/games"
mkdir -p "$FIXTURE_DIR/builtin-profiles/gambling"
mkdir -p "$FIXTURE_DIR/builtin-profiles/news"

export CURFEW_PROFILES_DIR="$FIXTURE_DIR/user-profiles"
export CURFEW_BUILTIN_PROFILES_DIR="$FIXTURE_DIR/builtin-profiles"

# shellcheck source=../completions/curfew.bash
source "$COMPLETION_FILE"

# -- tests ---------------------------------------------------------------

complete_at 1 curfew ""
assert_contains "first word offers user profiles" "work" "${COMPREPLY[@]}"
assert_contains "first word offers builtin profiles" "games" "${COMPREPLY[@]}"
assert_contains "first word offers --list" "--list" "${COMPREPLY[@]}"
assert_contains "first word offers --new" "--new" "${COMPREPLY[@]}"
assert_contains "first word offers --detect-games" "--detect-games" "${COMPREPLY[@]}"

complete_at 1 curfew "ga"
assert_contains "prefix 'ga' matches games" "games" "${COMPREPLY[@]}"
assert_contains "prefix 'ga' matches gambling" "gambling" "${COMPREPLY[@]}"
assert_not_contains "prefix 'ga' excludes news" "news" "${COMPREPLY[@]}"
assert_not_contains "prefix 'ga' excludes work" "work" "${COMPREPLY[@]}"

complete_at 2 curfew "work" "--f"
assert_contains "after profile, '--f' matches --for" "--for" "${COMPREPLY[@]}"

complete_at 2 curfew "work" ""
assert_contains "after profile, empty offers --for" "--for" "${COMPREPLY[@]}"
assert_contains "after profile, empty offers --until" "--until" "${COMPREPLY[@]}"

complete_at 3 curfew "work" "--for" ""
assert_empty "no more suggestions right after --for" "${COMPREPLY[@]}"

complete_at 3 curfew "work" "--for" "2h"
assert_empty "no suggestions for the duration value" "${COMPREPLY[@]}"

complete_at 3 curfew "--new" "focus" ""
assert_contains "after --new <name>, offers --from" "--from" "${COMPREPLY[@]}"

complete_at 2 curfew "--detect-games" ""
assert_empty "--detect-games takes no further arguments" "${COMPREPLY[@]}"

complete_at 1 curfew "--n"
assert_contains "'--n' still matches --new" "--new" "${COMPREPLY[@]}"
assert_not_contains "'--n' excludes profile names" "work" "${COMPREPLY[@]}"

echo
echo "$pass_count passed, $fail_count failed"
[[ "$fail_count" -eq 0 ]]

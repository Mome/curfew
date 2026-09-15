#!/usr/bin/env bash
# Plain-bash tests for `curfew <profile> --for/--until` (cmd_apply) — no test
# framework, mirrors test_completion.bash. Runs the real script as a
# subprocess with `sudo`/`nosudo`/`hblock` replaced by fixture scripts on
# PATH, so no real privileged command ever runs. Run directly:
#   bash tests/test_apply.bash

set -uo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
CURFEW="$SCRIPT_DIR/../curfew"

pass_count=0
fail_count=0

assert_success() {
  local desc="$1" status="$2"
  if [[ "$status" -eq 0 ]]; then
    pass_count=$((pass_count + 1))
  else
    fail_count=$((fail_count + 1))
    echo "FAIL: $desc — expected exit 0, got $status"
  fi
}

assert_failure() {
  local desc="$1" status="$2"
  if [[ "$status" -ne 0 ]]; then
    pass_count=$((pass_count + 1))
  else
    fail_count=$((fail_count + 1))
    echo "FAIL: $desc — expected a nonzero exit, got 0"
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    pass_count=$((pass_count + 1))
  else
    fail_count=$((fail_count + 1))
    echo "FAIL: $desc — expected to find '$needle'"
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    pass_count=$((pass_count + 1))
  else
    fail_count=$((fail_count + 1))
    echo "FAIL: $desc — did not expect to find '$needle'"
  fi
}

# Asserts $1 comes strictly before $2 in the mock call log, i.e. the
# sudo-requiring hosts-restore-timer setup ran while sudo was still usable,
# before `nosudo restrict` took it away.
assert_before() {
  local desc="$1" first="$2" second="$3" log="$4"
  local first_line second_line
  first_line="$(grep -n -F "$first" <<<"$log" | head -1 | cut -d: -f1)"
  second_line="$(grep -n -F "$second" <<<"$log" | head -1 | cut -d: -f1)"
  if [[ -n "$first_line" && -n "$second_line" && "$first_line" -lt "$second_line" ]]; then
    pass_count=$((pass_count + 1))
  else
    fail_count=$((fail_count + 1))
    echo "FAIL: $desc — expected '$first' before '$second' in:"
    echo "$log"
  fi
}

# -- fixtures ----------------------------------------------------------------

FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/curfew-apply-test.XXXXXX")"
trap 'rm -rf "$FIXTURE_DIR"' EXIT

mkdir -p "$FIXTURE_DIR/profiles/work" "$FIXTURE_DIR/bin"
: > "$FIXTURE_DIR/profiles/work/sources.list"
: > "$FIXTURE_DIR/profiles/work/deny.list"
: > "$FIXTURE_DIR/profiles/work/allow.list"

export MOCKLOG="$FIXTURE_DIR/mocklog"

# Fake sudo: logs every invocation, never touches the real filesystem.
# `test -f ...` always reports "no such backup", so cmd_apply never trips
# its "a curfew hosts-block is already active" guard. A `tee` call is fed
# its heredoc stdin, which is simply discarded.
cat > "$FIXTURE_DIR/bin/sudo" << 'EOF'
#!/usr/bin/env bash
echo "sudo $*" >> "$MOCKLOG"
if [[ -n "${SUDO_FAIL_MATCH:-}" && "$*" == *"$SUDO_FAIL_MATCH"* ]]; then
  exit 1
fi
[[ "$1" == "tee" ]] && cat >/dev/null
[[ "$1" == "test" ]] && exit 1
exit 0
EOF
chmod +x "$FIXTURE_DIR/bin/sudo"

# Fake nosudo: `--dry-run restrict` (called by resolve_lift_time_preview,
# before anything privileged happens) and a real `restrict` (called last,
# after the hosts-restore timer is set up) both print the one line cmd_apply
# parses; NOSUDO_RESTRICT_FAIL controls whether the real one fails.
cat > "$FIXTURE_DIR/bin/nosudo" << 'EOF'
#!/usr/bin/env bash
echo "nosudo $*" >> "$MOCKLOG"
user="$(id -un)"
case "$1" in
  --dry-run)
    echo "$user: sudo restricted until 2026-09-15 18:00 (5m from now)"
    ;;
  restrict)
    if [[ "${NOSUDO_RESTRICT_FAIL:-0}" == "1" ]]; then
      echo "nosudo: simulated failure" >&2
      exit 1
    fi
    echo "$user: sudo restricted until 2026-09-15 18:00 (5m from now)"
    ;;
esac
EOF
chmod +x "$FIXTURE_DIR/bin/nosudo"

cat > "$FIXTURE_DIR/bin/hblock" << 'EOF'
#!/usr/bin/env bash
echo "hblock $*" >> "$MOCKLOG"
EOF
chmod +x "$FIXTURE_DIR/bin/hblock"

run_apply() {
  : > "$MOCKLOG"
  PATH="$FIXTURE_DIR/bin:$PATH" \
    CURFEW_PROFILES_DIR="$FIXTURE_DIR/profiles" \
    CURFEW_BUILTIN_PROFILES_DIR="$FIXTURE_DIR/profiles" \
    bash "$CURFEW" work --for 5m
}

# -- tests --------------------------------------------------------------

# Happy path: the hosts-restore timer must be fully installed *before*
# `nosudo restrict` runs, and the whole thing must exit 0 with no bash
# "unbound variable" error (regression: an EXIT trap used to reference a
# `local` merge_dir that was already out of scope by the time it fired).
output="$(run_apply 2>&1)"
status=$?
log="$(cat "$MOCKLOG")"
assert_success "happy path exits 0" "$status"
assert_not_contains "happy path prints no output" "unbound variable" "$output"
assert_before "restore-timer files written before sudo is locked" \
  "sudo tee" "nosudo restrict --for 5m" "$log"
assert_before "restore-timer enabled before sudo is locked" \
  "systemctl enable" "nosudo restrict --for 5m" "$log"

# `nosudo restrict` failing (for any reason) after the timer is installed
# must revert /etc/hosts and the partial timer, and must not surface an
# unbound-variable error.
output="$(NOSUDO_RESTRICT_FAIL=1 run_apply 2>&1)"
status=$?
assert_failure "nosudo restrict failure exits nonzero" "$status"
assert_not_contains "nosudo restrict failure: no unbound variable" "unbound variable" "$output"
assert_contains "nosudo restrict failure: /etc/hosts is reverted" "cp -f" "$(cat "$MOCKLOG")"

# The original bug report: sudo denies the `tee restore-hosts.sh` call
# inside install_hosts_restore_timer. Must abort and clean up gracefully
# instead of crashing on an unrelated unbound-variable error.
output="$(SUDO_FAIL_MATCH="tee" run_apply 2>&1)"
status=$?
assert_failure "sudo tee denial exits nonzero" "$status"
assert_not_contains "sudo tee denial: no unbound variable" "unbound variable" "$output"
assert_not_contains "sudo tee denial: nosudo restrict never runs" "nosudo restrict --for 5m" "$(cat "$MOCKLOG")"

echo
echo "$pass_count passed, $fail_count failed"
[[ "$fail_count" -eq 0 ]]

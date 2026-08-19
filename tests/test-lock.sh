#!/usr/bin/env bash
# lib/lock.sh on its own: the behaviours everything else is built on.
set -uo pipefail
PR_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PR_ROOT/tests/helpers.sh"
source "$PR_ROOT/lib/paths.sh"
source "$PR_ROOT/lib/lock.sh"


# A pid that is certainly not in use: started, exited, and reaped.
dead_pid() {
  local p
  true & p=$!
  wait "$p" 2> /dev/null
  printf '%s' "$p"
}

test_acquiring_a_free_lock_records_the_holders_pid() {
  local d out pid self; d="$(pr_test_tmpdir)"
  out="$(PR_ROOT="$PR_ROOT" LOCK="$d/.lock" bash -c '
    source "$PR_ROOT/lib/lock.sh"
    pr_lock_acquire "$LOCK"; echo "rc=$?"
    echo "pid=$(cat "$LOCK")"
    echo "self=$$"' 2>&1)"
  assert_contains "$out" "rc=0" "acquired"
  pid="$(sed -n 's/^pid=//p' <<< "$out")"
  self="$(sed -n 's/^self=//p' <<< "$out")"
  assert_eq "$pid" "$self" "the lock file names the process that took it"
}

test_a_second_holder_is_refused_with_the_busy_code() {
  local d rc; d="$(pr_test_tmpdir)"
  pr_test_hold_lock "$d/.lock" "$d/release"
  ( PR_LOCK_WAIT_SECS=0.1; pr_lock_acquire "$d/.lock" ) 2> /dev/null; rc=$?
  pr_test_release_lock "$d/release"
  assert_exit_code "$rc" 75 "contention has its own exit code"
}

# The bug this is here for: `exec 9> lk` truncates at open time, BEFORE flock
# runs, so a process that only ever WAITED would erase the holder's pid and then
# have an empty file to report from.
test_a_waiter_does_not_truncate_the_holders_pid() {
  local d; d="$(pr_test_tmpdir)"
  pr_test_hold_lock "$d/.lock" "$d/release"
  ( PR_LOCK_WAIT_SECS=0.1; pr_lock_acquire "$d/.lock" ) 2> /dev/null
  assert_eq "$(pr_lock_pid "$d/.lock")" "$PR_TEST_HOLDER" \
    "the holder's pid survived the waiter"
  pr_test_release_lock "$d/release"
}

# The whole design in one case: a child inherits the descriptor, so the session
# stays held even though the process that started it has been SIGKILLed. A pid
# check cannot answer this, because the runner is the process that is gone.
test_the_lock_outlives_a_killed_parent_through_its_children() {
  local d rc i; d="$(pr_test_tmpdir)"
  : > "$d/release"
  # The parent blocks in `wait`, a builtin: anything that forked would leave a
  # second process holding the inherited descriptor and muddy the second half.
  PR_ROOT="$PR_ROOT" D="$d" bash -c '
    source "$PR_ROOT/lib/lock.sh"
    pr_lock_acquire "$D/.lock" || exit 1
    ( while [[ -e "$D/release" ]]; do sleep 0.05; done ) &
    echo $! > "$D/child.pid"
    echo $$ > "$D/parent.pid"
    wait' > /dev/null 2>&1 &
  local runner=$!
  for ((i = 0; i < 500; i++)); do [[ -s "$d/child.pid" ]] && break; sleep 0.02; done

  kill -9 "$(cat "$d/parent.pid")" 2> /dev/null
  wait "$runner" 2> /dev/null

  ( PR_LOCK_WAIT_SECS=0.1; pr_lock_acquire "$d/.lock" ) 2> /dev/null; rc=$?
  assert_exit_code "$rc" 75 "an orphan still holds the session"

  rm -f "$d/release"
  for ((i = 0; i < 500; i++)); do
    kill -0 "$(cat "$d/child.pid")" 2> /dev/null || break
    sleep 0.05
  done
  ( PR_LOCK_WAIT_SECS=0.1; pr_lock_acquire "$d/.lock" ) 2> /dev/null; rc=$?
  assert_exit_code "$rc" 0 "released once the last holder exited"
}

test_probe_reports_held_and_free_without_keeping_the_lock() {
  local d rc; d="$(pr_test_tmpdir)"
  pr_lock_probe "$d/.lock"; rc=$?
  assert_exit_code "$rc" 0 "no lock file means nothing is held"
  assert_file_missing "$d/.lock" "probing does not create the file"

  pr_test_hold_lock "$d/.lock" "$d/release"
  pr_lock_probe "$d/.lock"; rc=$?
  assert_exit_code "$rc" 75 "held"
  pr_test_release_lock "$d/release"

  pr_lock_probe "$d/.lock"; rc=$?
  assert_exit_code "$rc" 0 "free again, and the probe let go of it"
}

test_an_unopenable_lock_is_an_operational_failure_not_a_busy_session() {
  local d rc err; d="$(pr_test_tmpdir)"
  [[ "$EUID" -ne 0 ]] || return 0   # root opens anything; the case cannot exist
  mkdir -p "$d/closed"
  chmod 500 "$d/closed"
  err="$( ( pr_lock_acquire "$d/closed/.lock" ) 2>&1 )"; rc=$?
  chmod 700 "$d/closed"
  assert_exit_code "$rc" 2 "operational, never 75"
  assert_contains "$err" "could not open the session lock" "says what actually failed"
}

# PR_DOCTOR_UTILS does not reach a round, so this is the check that actually
# stops one on a machine without flock.
test_a_missing_flock_is_named_at_the_lock_site() {
  local d p rc err u real; d="$(pr_test_tmpdir)"
  p="$d/path"; mkdir -p "$p"
  for u in env bash; do real="$(command -v "$u")" && ln -s "$real" "$p/$u"; done
  err="$(PATH="$p" PR_ROOT="$PR_ROOT" LOCK="$d/.lock" "$BASH" -c '
    source "$PR_ROOT/lib/lock.sh"
    pr_lock_acquire "$LOCK"' 2>&1)"; rc=$?
  assert_exit_code "$rc" 2 "refused"
  assert_contains "$err" "flock is required" "names the missing tool"
  assert_contains "$err" "util-linux" "and the package that carries it"
  assert_file_missing "$d/.lock" "nothing was created before the check"
}

test_a_lock_file_with_no_pid_still_explains_itself() {
  local d out; d="$(pr_test_tmpdir)"
  : > "$d/.lock"
  out="$(pr_lock_explain "$d/.lock" somekey 2>&1)"
  assert_contains "$out" "No pid was recorded" "the refusal does not depend on the pid"
}

# The recovery hint is a fixed-string search precisely because pr_plan_slug does
# not sanitise: a plan named v1.2+final.md puts a `+` in this path, where pgrep
# would match nothing and report a busy session as idle.
test_the_recovery_hint_is_a_fixed_string_search() {
  local d out; d="$(pr_test_tmpdir)"
  dead_pid > "$d/.lock"
  out="$(PR_CACHE_ROOT=/c pr_lock_explain "$d/.lock" 'abc-v1.2+final' 2>&1)"
  assert_contains "$out" "grep -F '/c/abc-v1.2+final'" "literal, and escapes nothing"
  assert_not_contains "$out" "pgrep" "never a regular-expression matcher"
  assert_not_contains "$out" "kill $(cat "$d/.lock")" "never names a pid as a target"
}

test_a_live_pid_is_reported_as_running() {
  local d out; d="$(pr_test_tmpdir)"
  printf '%s\n' "$$" > "$d/.lock"
  out="$(pr_lock_explain "$d/.lock" somekey 2>&1)"
  assert_contains "$out" "still running" "says the starter is alive"
  assert_not_contains "$out" "grep -F" "no orphan hunt is needed"
}

pr_run_tests

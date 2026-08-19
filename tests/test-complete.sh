#!/usr/bin/env bash
set -uo pipefail
PR_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PR_ROOT/tests/helpers.sh"
source "$PR_ROOT/lib/round.sh"

COMPLETE="$PR_ROOT/bin/plan-review"
STUB_BIN="$PR_ROOT/tests/fixtures/bin"

# A round awaiting integration with two ok reviewers and one failed.
make_round() {
  local rd="$1"
  mkdir -p "$rd"
  jq -n '{round: 1, state: "awaiting_integration", reviewers: {
            codex: {status: "ok"}, agent: {status: "ok"}, agy: {status: "failed"}}}' \
    > "$rd/round.json"
}

test_completes_when_every_ok_reviewer_has_a_rationale() {
  local d rd rc; d="$(pr_test_tmpdir)"; rd="$d/round-1"; make_round "$rd"
  echo r > "$rd/rationale-codex.md"
  echo r > "$rd/rationale-agent.md"
  bash "$COMPLETE" complete --round "$rd" > /dev/null 2>&1; rc=$?
  assert_exit_code "$rc" 0 "completes"
  assert_eq "$(jq -r '.state' < "$rd/round.json")" "complete" "state advanced"
}

test_a_failed_reviewer_needs_no_rationale() {
  local d rd rc; d="$(pr_test_tmpdir)"; rd="$d/round-1"; make_round "$rd"
  echo r > "$rd/rationale-codex.md"
  echo r > "$rd/rationale-agent.md"
  bash "$COMPLETE" complete --round "$rd" > /dev/null 2>&1; rc=$?
  assert_exit_code "$rc" 0 "agy produced nothing to respond to"
}

test_refuses_when_a_rationale_is_missing() {
  local d rd rc out; d="$(pr_test_tmpdir)"; rd="$d/round-1"; make_round "$rd"
  echo r > "$rd/rationale-codex.md"
  out="$(bash "$COMPLETE" complete --round "$rd" 2>&1)"; rc=$?
  assert_exit_code "$rc" 1 "refuses"
  assert_contains "$out" "agent" "names the reviewer still owed a rationale"
  assert_eq "$(jq -r '.state' < "$rd/round.json")" "awaiting_integration" "state unchanged"
}

test_refuses_when_a_rationale_is_empty() {
  local d rd rc; d="$(pr_test_tmpdir)"; rd="$d/round-1"; make_round "$rd"
  echo r > "$rd/rationale-codex.md"
  : > "$rd/rationale-agent.md"
  bash "$COMPLETE" complete --round "$rd" > /dev/null 2>&1; rc=$?
  assert_exit_code "$rc" 1 "an empty file is not a rationale"
}

test_completing_twice_is_harmless() {
  local d rd rc; d="$(pr_test_tmpdir)"; rd="$d/round-1"; make_round "$rd"
  echo r > "$rd/rationale-codex.md"
  echo r > "$rd/rationale-agent.md"
  bash "$COMPLETE" complete --round "$rd" > /dev/null 2>&1
  bash "$COMPLETE" complete --round "$rd" > /dev/null 2>&1; rc=$?
  assert_exit_code "$rc" 0 "idempotent"
  assert_eq "$(jq -r '.state' < "$rd/round.json")" "complete" "still complete"
}

test_refuses_an_aborted_round() {
  local d rd rc out; d="$(pr_test_tmpdir)"; rd="$d/round-1"; make_round "$rd"
  jq '.state = "aborted"' < "$rd/round.json" > "$rd/t" && mv "$rd/t" "$rd/round.json"
  out="$(bash "$COMPLETE" complete --round "$rd" 2>&1)"; rc=$?
  assert_exit_code "$rc" 1 "nothing to integrate"
  assert_contains "$out" "aborted" "says why"
}

# --- the session lock -------------------------------------------------------

test_refuses_while_the_session_is_locked() {
  local d rd rc out; d="$(pr_test_tmpdir)"; rd="$d/round-1"; make_round "$rd"
  echo r > "$rd/rationale-codex.md"
  echo r > "$rd/rationale-agent.md"
  pr_test_hold_lock "$d/.lock" "$d/release"
  out="$(PR_LOCK_WAIT_SECS=0.1 bash "$COMPLETE" complete --round "$rd" 2>&1)"; rc=$?
  pr_test_release_lock "$d/release"
  assert_exit_code "$rc" 1 "refused"
  assert_contains "$out" "locked" "says the session is busy"
  assert_eq "$(jq -r '.state' < "$rd/round.json")" "awaiting_integration" "state unchanged"
}

# `abort` is a second writer of round.json, so `complete` must not act on a state
# it read before it had the right to.
#
# The assertion is on the FILE, not on the exit code. complete refuses on
# `aborted` whether or not it re-read; what separates the two is that a missing
# re-read writes `complete` over it. The ordering handshake is a stub flock that
# touches a marker and then becomes the real one: the marker proves complete has
# finished its first read and reached the lock, which is the only moment at which
# mutating round.json proves anything. Deterministic -- nothing races.
test_re_reads_the_state_after_taking_the_lock() {
  local d rd i real; d="$(pr_test_tmpdir)"; rd="$d/round-1"; make_round "$rd"
  echo r > "$rd/rationale-codex.md"
  echo r > "$rd/rationale-agent.md"
  real="$(command -v flock)"

  pr_test_hold_lock "$d/.lock" "$d/release"
  PATH="$STUB_BIN:$PATH" PR_TEST_FLOCK_MARKER="$d/reached-the-lock" \
  PR_TEST_REAL_FLOCK="$real" \
    bash "$COMPLETE" complete --round "$rd" > "$d/out.txt" 2>&1 &
  local completer=$!
  for ((i = 0; i < 500; i++)); do
    [[ -e "$d/reached-the-lock" ]] && break
    sleep 0.02
  done
  assert_file_exists "$d/reached-the-lock" "complete reached the lock"

  # Still holding it, so complete cannot possibly have acted yet.
  jq '.state = "aborted"' < "$rd/round.json" > "$rd/t" && mv "$rd/t" "$rd/round.json"
  pr_test_release_lock "$d/release"
  wait "$completer" 2> /dev/null

  assert_eq "$(jq -r '.state' < "$rd/round.json")" "aborted" \
    "complete did not write over a state it never re-read"
}

pr_run_tests

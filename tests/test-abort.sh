#!/usr/bin/env bash
# `plan-review abort`: the executable remedy for a round nothing is working on.
set -uo pipefail
PR_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PR_ROOT/tests/helpers.sh"

PR="$PR_ROOT/bin/plan-review"
FAKES="$PR_ROOT/tests/fixtures/adapters"

# A round directory inside a session directory, in the given state. Nothing else
# is needed: abort reads one field and writes one field.
make_round() {
  local rd="$1" state="$2"
  mkdir -p "$rd"
  jq -n --arg s "$state" '{round: 1, state: $s, reviewers: {}}' > "$rd/round.json"
}

abort() {  # abort <round-dir>
  PR_LOCK_WAIT_SECS=0.1 bash "$PR" abort --round "$1" 2>&1
}

state_of() { jq -r '.state' < "$1/round.json"; }

make_target() {
  local root="$1"
  mkdir -p "$root/docs"
  pr_test_git_init_identity "$root"
  printf '# Plan\n\nDo the thing.\n' > "$root/docs/plan.md"
  git -C "$root" add -A
  git -C "$root" commit -qm init
}

# --- states -----------------------------------------------------------------

test_aborts_a_crashed_round() {
  local d rd out rc; d="$(pr_test_tmpdir)"; rd="$d/session/round-1"
  make_round "$rd" reviewing
  out="$(abort "$rd")"; rc=$?
  assert_exit_code "$rc" 0 "a crashed round is exactly what this is for"
  assert_eq "$(state_of "$rd")" "aborted" "state advanced"
  assert_contains "$out" "$rd" "names the round it finalised"
}

# Abandoning a round that produced reviews but will never get rationale is a
# legitimate decision, and the only alternative was hand-editing JSON.
test_aborts_a_round_awaiting_integration() {
  local d rd rc; d="$(pr_test_tmpdir)"; rd="$d/session/round-1"
  make_round "$rd" awaiting_integration
  abort "$rd" > /dev/null; rc=$?
  assert_exit_code "$rc" 0 "abandoning is allowed"
  assert_eq "$(state_of "$rd")" "aborted" "state advanced"
}

test_aborting_twice_is_harmless() {
  local d rd rc; d="$(pr_test_tmpdir)"; rd="$d/session/round-1"
  make_round "$rd" reviewing
  abort "$rd" > /dev/null
  abort "$rd" > /dev/null; rc=$?
  assert_exit_code "$rc" 0 "idempotent"
  assert_eq "$(state_of "$rd")" "aborted" "still aborted"
}

# Reopening a finished round discards the record that it completed, and
# pr_round_can_start treats the two identically, so nothing would be gained.
test_refuses_a_complete_round() {
  local d rd out rc; d="$(pr_test_tmpdir)"; rd="$d/session/round-1"
  make_round "$rd" complete
  out="$(abort "$rd")"; rc=$?
  assert_exit_code "$rc" 1 "refused"
  assert_contains "$out" "complete" "names the state"
  assert_eq "$(state_of "$rd")" "complete" "state unchanged"
}

test_refuses_an_unreadable_round_json() {
  local d rd out rc; d="$(pr_test_tmpdir)"; rd="$d/session/round-1"
  mkdir -p "$rd"; printf '{not json' > "$rd/round.json"
  out="$(abort "$rd")"; rc=$?
  assert_exit_code "$rc" 1 "an unknown state is not an abortable one"
  assert_contains "$out" "unreadable" "says what it read"
}

test_refuses_a_relative_round() {
  local out rc
  out="$(bash "$PR" abort --round some/round-1 2>&1)"; rc=$?
  assert_exit_code "$rc" 2 "refused before doing anything"
  assert_contains "$out" "must be absolute" "says why"
}

test_refuses_a_directory_with_no_round_json() {
  local d out rc; d="$(pr_test_tmpdir)"; mkdir -p "$d/session/round-1"
  out="$(abort "$d/session/round-1")"; rc=$?
  assert_exit_code "$rc" 2 "nothing to abort"
  assert_contains "$out" "no round.json" "names what is missing"
}

# A round predating the session lock has no .lock file, which reads as "nothing
# held" -- which is correct.
test_a_session_with_no_lock_file_aborts_without_complaint() {
  local d rd rc; d="$(pr_test_tmpdir)"; rd="$d/session/round-1"
  make_round "$rd" reviewing
  assert_file_missing "$d/session/.lock" "no lock file to begin with"
  abort "$rd" > /dev/null; rc=$?
  assert_exit_code "$rc" 0 "aborted"
}

# On a store-loss round the runner's own message points the operator at
# `abort` -- which cannot work: pr_round_set_state writes through a temp file
# in the directory that just refused the write. Reproduced on the unguarded
# command: `lib/round.sh: line 195: ....tmp: Permission denied`, exit 2, state
# still reviewing. The preflight exists ONLY because abort cannot possibly
# succeed here and so has something better to say; the raw write errors on the
# ROUND path are the diagnostic and stay (see the comment in the command).
test_refuses_an_unwritable_round_directory_with_one_sentence() {
  (( EUID != 0 )) || { pr_test_skip "root writes anywhere; the case cannot exist"; return 0; }
  local d rd out rc; d="$(pr_test_tmpdir)"; rd="$d/session/round-1"
  make_round "$rd" reviewing
  chmod a-w "$rd"
  out="$(abort "$rd")"; rc=$?
  chmod u+w "$rd"
  assert_exit_code "$rc" 2 "store loss is exit 2, matching the round's own aborts"
  assert_eq "$out" "the artifact store refuses writes: $rd; retry after restoring store writes" \
    "exactly the one sentence -- no raw jq temp-file error before or after it"
  assert_eq "$(state_of "$rd")" "reviewing" "state unchanged"
}

# Locked AND unwritable reports the lock: "a review is still running" is the
# truth that matters first, and the preflight sits after pr_lock_hold so a
# genuinely running round in an unwritable directory is never misdiagnosed as
# storage trouble.
test_a_locked_session_outranks_an_unwritable_round_directory() {
  (( EUID != 0 )) || { pr_test_skip "root writes anywhere; the case cannot exist"; return 0; }
  local d rd out rc; d="$(pr_test_tmpdir)"; rd="$d/session/round-1"
  make_round "$rd" reviewing
  chmod a-w "$rd"
  pr_test_hold_lock "$d/session/.lock" "$d/release"
  out="$(abort "$rd")"; rc=$?
  pr_test_release_lock "$d/release"
  chmod u+w "$rd"
  assert_exit_code "$rc" 1 "the lock refusal, not the storage one"
  assert_contains "$out" "locked" "and it says so"
}

# --- the lock ---------------------------------------------------------------

test_refuses_while_the_session_is_locked_and_changes_nothing() {
  local d rd out rc before after; d="$(pr_test_tmpdir)"; rd="$d/session/round-1"
  make_round "$rd" reviewing
  before="$(cksum < "$rd/round.json")"
  pr_test_hold_lock "$d/session/.lock" "$d/release"
  out="$(abort "$rd")"; rc=$?
  after="$(cksum < "$rd/round.json")"
  pr_test_release_lock "$d/release"
  assert_exit_code "$rc" 1 "refused"
  assert_contains "$out" "locked" "says the session is busy"
  assert_contains "$out" "$PR_TEST_HOLDER" "names who started it"
  assert_eq "$after" "$before" "round.json is byte-identical"
}

# The lock is per session and abort names a round: re-aborting round 3 must not
# be refused because round 4 legitimately holds the session. Repeating a command
# that already succeeded should not be told no.
test_re_aborting_succeeds_even_while_another_round_holds_the_session() {
  local d rd rc; d="$(pr_test_tmpdir)"; rd="$d/session/round-1"
  make_round "$rd" aborted
  pr_test_hold_lock "$d/session/.lock" "$d/release"
  abort "$rd" > /dev/null; rc=$?
  pr_test_release_lock "$d/release"
  assert_exit_code "$rc" 0 "the terminal state is read before the lock is taken"
}

# The case the whole design exists for. `kill -9` on the runner does not free the
# session, because the reviewer it spawned inherited the lock's descriptor.
test_a_killed_runner_with_a_live_reviewer_still_blocks_abort() {
  local d art rd out rc i runner; d="$(pr_test_tmpdir)"; make_target "$d/target"
  : > "$d/hold"
  PR_CACHE_ROOT="$d/cache" PR_ADAPTER_MAP="codex=$FAKES/fake-slow.sh" \
  PR_ORCHESTRATOR=none PR_TIMEOUT_SECS=120 \
  PR_TEST_HOLD="$d/hold" PR_TEST_ADAPTER_PIDFILE="$d/adapter.pid" \
    bash "$PR" round --repo "$d/target" --plan docs/plan.md > /dev/null 2>&1 &
  runner=$!
  for ((i = 0; i < 1000; i++)); do [[ -s "$d/adapter.pid" ]] && break; sleep 0.05; done
  [[ -s "$d/adapter.pid" ]] || { pr_fail "the reviewer never started"; kill -9 "$runner"; return; }

  kill -9 "$runner"; wait "$runner" 2> /dev/null
  art="$(ls -d "$d/target/.plan-review/"*/)"; art="${art%/}"; rd="$art/round-1"

  out="$(abort "$rd")"; rc=$?
  assert_exit_code "$rc" 1 "an orphaned reviewer still holds the session"
  assert_contains "$out" "no longer running" "the runner is gone; its children are not"
  assert_contains "$out" "grep -F" "and there is a way to find them"
  assert_eq "$(state_of "$rd")" "reviewing" "nothing was written"

  rm -f "$d/hold"
  for ((i = 0; i < 1000; i++)); do
    abort "$rd" > /dev/null && break
    sleep 0.05
  done
  assert_eq "$(state_of "$rd")" "aborted" "abort succeeds once the last holder exits"
}

pr_run_tests

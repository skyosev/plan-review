#!/usr/bin/env bash
set -uo pipefail
PR_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PR_ROOT/tests/helpers.sh"
source "$PR_ROOT/lib/paths.sh"
source "$PR_ROOT/lib/status.sh"
source "$PR_ROOT/lib/sandbox.sh"
source "$PR_ROOT/lib/prompt.sh"
source "$PR_ROOT/lib/session.sh"
source "$PR_ROOT/lib/verdict.sh"
source "$PR_ROOT/lib/adapter-exec.sh"
source "$PR_ROOT/lib/reviewer-runner.sh"

FAKES="$PR_ROOT/tests/fixtures/adapters"

# Builds the whole variable contract around a throwaway repo, so a test drives
# pr_reviewer_run_all exactly as libexec/plan-review-round.sh does. All
# assignments are deliberately global: the contract is dynamic scope, and that
# is the interface under test. A plain directory stands in for the repo --
# pr_sandbox_refresh tolerates a non-git target, and nothing here reads git.
setup_session() {
  local d="$1"
  repo="$d/repo"
  mkdir -p "$repo/docs"
  echo "# plan" > "$repo/docs/plan.md"
  PR_CACHE_ROOT="$d/cache"
  session_key="k-test"
  artifact_dir="$d/art"
  round=1
  round_dir="$artifact_dir/round-1"
  mkdir -p "$round_dir"
  cp "$repo/docs/plan.md" "$round_dir/plan.snapshot.md"
  fresh_flag=false
  status_file="$round_dir/status.jsonl"
  pr_status_init "$status_file"
  session_map="$artifact_dir/session-map.json"
  criteria_initial="" criteria_rereview=""
  PR_TIMEOUT_SECS=30
  PR_KILL_GRACE_SECS=1
}

# The nine-field producer schema, asserted where the producer lives. The
# consumer fixture in tests/test-round.sh deliberately carries only the seven
# fields pr_round_record_reviewer reads; this is the test that owns the rest.
test_the_result_record_round_trips_and_carries_nine_fields() {
  local d round_dir; d="$(pr_test_tmpdir)"; round_dir="$d"
  _pr_reviewer_result_write r1 ok "kept" MINOR sess-1 model-1 effort-1 cli-1 true true
  assert_eq "$(jq -r 'keys_unsorted | join(",")' < "$round_dir/.result-r1")" \
    "status,detail,verdict,session,model,effort,cli,discard,timed_out" \
    "nine fields, in the stated order"
  local status session discard timed_out
  pr_reviewer_result_read r1 status session discard timed_out
  assert_eq "$status" "ok" "status read back"
  assert_eq "$session" "sess-1" "session read back"
  assert_eq "$discard" "true" "discard read back"
  assert_eq "$timed_out" "true" "timed_out read back"
}

test_exit_detail_names_the_consistent_signal_without_asserting_delivery() {
  local detail; detail="$(_pr_reviewer_exit_detail 143)"
  assert_contains "$detail" "SIGTERM" "143 names the signal it is consistent with"
  assert_contains "$detail" "deadline had not elapsed" "and states what the runner knows"
  assert_eq "$(_pr_reviewer_exit_detail 2)" "exit 2" "a plain code stays plain"
}

# set -u checks existence at first USE, inside a backgrounded child whose death
# leaves a missing result record. The validation must refuse loudly and
# synchronously, before anything spawns.
test_run_all_refuses_an_incomplete_contract_before_spawning() {
  local d out rc; d="$(pr_test_tmpdir)"
  setup_session "$d"
  unset session_map
  out="$(pr_reviewer_run_all "codex=$FAKES/fake-ok.sh" 2>&1)"; rc=$?
  assert_exit_code "$rc" 2 "a broken contract is a refusal"
  assert_contains "$out" "session_map" "and the refusal names the variable"
  assert_eq "$(cat "$status_file")" "" "nothing spawned: no status event"
  assert_file_missing "$round_dir/.result-codex" "and no record was written"
}

# The overlap property nothing in tests/test-runner.sh asserts: a later
# "simplification" of the fan-out into a serial loop would pass all 46
# end-to-end tests. Two handshake fakes each wait for the other's marker;
# serial execution makes the first give up with no review.
test_run_all_runs_reviewers_concurrently() {
  local d; d="$(pr_test_tmpdir)"
  setup_session "$d"
  # local -x, not export: the fixture is a separate process and must find this
  # in its environment, but the variable dies with this function instead of
  # leaking a stale marker dir into a second handshake test.
  local -x PR_TEST_HANDSHAKE_DIR="$d/hs"
  mkdir -p "$PR_TEST_HANDSHAKE_DIR"
  PR_TIMEOUT_SECS=20
  pr_reviewer_run_all "alpha=$FAKES/fake-handshake.sh beta=$FAKES/fake-handshake.sh"
  local status session discard timed_out
  pr_reviewer_result_read alpha status session discard timed_out
  assert_eq "$status" "ok" "alpha finished: the reviewers overlapped"
  assert_eq "$timed_out" "false" "and no deadline was involved"
  pr_reviewer_result_read beta status session discard timed_out
  assert_eq "$status" "ok" "beta finished too"
}

# Library safety: bare `wait` in a sourced function blocks on and reaps a
# caller's unrelated background job. run_all must wait on the pids it
# collected and nothing else.
test_run_all_does_not_wait_for_an_unrelated_child() {
  local d bystander; d="$(pr_test_tmpdir)"
  setup_session "$d"
  sleep 30 &
  bystander=$!
  pr_reviewer_run_all "codex=$FAKES/fake-ok.sh"
  if ! kill -0 "$bystander" 2> /dev/null; then
    pr_fail "the unrelated child was reaped: run_all waited on jobs it did not start"
  fi
  kill -9 "$bystander" 2> /dev/null
  wait "$bystander" 2> /dev/null
  local status session discard timed_out
  pr_reviewer_result_read codex status session discard timed_out
  assert_eq "$status" "ok" "and the reviewer itself completed"
}

pr_run_tests

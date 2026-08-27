#!/usr/bin/env bash
set -uo pipefail
PR_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PR_ROOT/tests/helpers.sh"

RUNNER="$PR_ROOT/bin/plan-review"
COMPLETE="$PR_ROOT/bin/plan-review"
FAKES="$PR_ROOT/tests/fixtures/adapters"
source "$PR_ROOT/lib/paths.sh"   # pr_session_key, for the cases that need the path

# Starts a round in the background whose reviewer hangs until <hold> is deleted,
# and returns once that reviewer is really running. The reviewer records its own
# pid: a pattern search would match the test's own shells, and these sandbox
# paths are not safe as regular expressions.
PR_TEST_ROUND=""
start_held_round() {  # start_held_round <target> <cache> <hold> <adapter-pidfile>
  local target="$1" cache="$2" hold="$3" pidfile="$4" i
  : > "$hold"
  PR_CACHE_ROOT="$cache" PR_ADAPTER_MAP="codex=$FAKES/fake-slow.sh" \
  PR_ORCHESTRATOR=none PR_TIMEOUT_SECS=120 \
  PR_TEST_HOLD="$hold" PR_TEST_ADAPTER_PIDFILE="$pidfile" \
    bash "$RUNNER" round --repo "$target" --plan docs/plan.md > /dev/null 2>&1 &
  PR_TEST_ROUND=$!
  for ((i = 0; i < 1000; i++)); do
    [[ -s "$pidfile" ]] && return 0
    sleep 0.05
  done
  pr_fail "the held round never reached its reviewer"
}

# Writes a rationale for every ok reviewer, then marks the round complete.
# The runner refuses to start the next round until this has happened.
complete_round() {
  local rd="$1" r
  for r in $(jq -r '.reviewers | to_entries[] | select(.value.status=="ok") | .key' \
               < "$rd/round.json"); do
    echo "accepted, see plan" > "$rd/rationale-$r.md"
  done
  bash "$COMPLETE" complete --round "$rd"
}

# Creates a target repo containing a plan, and returns its path via stdout.
make_target() {
  local root="$1"
  mkdir -p "$root/docs"
  pr_test_git_init_identity "$root"
  printf '# Plan\n\nDo the thing.\n' > "$root/docs/plan.md"
  git -C "$root" add -A
  git -C "$root" commit -qm init
}

run_round() {
  # run_round <target> <cache> <roster-spec...>
  # roster-spec is reviewer=adapter-file
  #
  # PR_ORCHESTRATOR defaults to `none` here and nowhere else: the runner refuses
  # to guess one. `none` is the truthful value for a test suite -- no agent is
  # orchestrating.
  local target="$1" cache="$2"; shift 2
  PR_CACHE_ROOT="$cache" PR_ADAPTER_MAP="$*" PR_TIMEOUT_SECS="${PR_TIMEOUT_SECS:-60}" \
  PR_ORCHESTRATOR="${PR_ORCHESTRATOR:-none}" \
    bash "$RUNNER" round --repo "$target" --plan docs/plan.md
}

# PR_TIMEOUT_SECS feeds bash arithmetic in adapters/agy.sh, which GNU timeout's
# accepted `1.5` would break with a syntax error deep inside a reviewer. The
# check is in the runner, not preflight, because PR_SKIP_PREFLIGHT=1 turns
# preflight off.
test_fractional_timeout_is_refused() {
  local d out rc; d="$(pr_test_tmpdir)"; make_target "$d/target"
  out="$(PR_TIMEOUT_SECS=1.5 run_round "$d/target" "$d/cache" \
    "codex=$FAKES/fake-ok.sh" 2>&1)"; rc=$?
  assert_exit_code "$rc" 2 "refused before the round started"
  assert_contains "$out" "PR_TIMEOUT_SECS" "names the variable"
  assert_file_missing "$d/target/.plan-review" "no round directory was left behind"
}

test_fractional_timeout_is_refused_even_with_preflight_skipped() {
  local d out rc; d="$(pr_test_tmpdir)"; make_target "$d/target"
  out="$(PR_SKIP_PREFLIGHT=1 PR_TIMEOUT_SECS=0 run_round "$d/target" "$d/cache" \
    "codex=$FAKES/fake-ok.sh" 2>&1)"; rc=$?
  assert_exit_code "$rc" 2 "zero is not a positive integer"
  assert_contains "$out" "PR_TIMEOUT_SECS" "names the variable"
}

test_round_one_produces_a_review_per_reviewer() {
  local d; d="$(pr_test_tmpdir)"; make_target "$d/target"
  run_round "$d/target" "$d/cache" "codex=$FAKES/fake-ok.sh" "agy=$FAKES/fake-ok.sh" > "$d/out.txt" 2>&1
  local art; art="$(ls -d "$d/target/.plan-review/"*/)"
  assert_file_exists "$art/round-1/review-codex.md" "codex review"
  assert_file_exists "$art/round-1/review-agy.md" "agy review"
  assert_file_exists "$art/round-1/plan.snapshot.md" "plan snapshot"
  assert_file_missing "$art/round-1/plan.diff" "no diff in round 1"
}

test_verdicts_and_files_are_recorded_in_round_json() {
  local d art; d="$(pr_test_tmpdir)"; make_target "$d/target"
  run_round "$d/target" "$d/cache" "codex=$FAKES/fake-ok.sh" > /dev/null 2>&1
  art="$(ls -d "$d/target/.plan-review/"*/)"
  assert_eq "$(jq -r '.reviewers.codex.verdict' < "$art/round-1/round.json")" "MINOR" "verdict"
  assert_eq "$(jq -r '.state' < "$art/round-1/round.json")" "awaiting_integration" "runner state"
  assert_contains "$(cat "$art/round-1/files-inspected-codex.txt")" "src/a.ts" "file list written"
}

test_a_failing_reviewer_does_not_sink_the_round() {
  local d art; d="$(pr_test_tmpdir)"; make_target "$d/target"
  run_round "$d/target" "$d/cache" "codex=$FAKES/fake-ok.sh" "agy=$FAKES/fake-fail.sh" > /dev/null 2>&1
  art="$(ls -d "$d/target/.plan-review/"*/)"
  assert_file_exists "$art/round-1/review-codex.md" "sibling review survives"
  assert_eq "$(jq -r '.reviewers.agy.status' < "$art/round-1/round.json")" "failed" "failure recorded"
  assert_eq "$(jq -r '.reviewers.codex.status' < "$art/round-1/round.json")" "ok" "sibling ok"
}

test_all_reviewers_failing_aborts_the_round() {
  local d art rc; d="$(pr_test_tmpdir)"; make_target "$d/target"
  run_round "$d/target" "$d/cache" "codex=$FAKES/fake-fail.sh" > /dev/null 2>&1; rc=$?
  art="$(ls -d "$d/target/.plan-review/"*/)"
  assert_exit_code "$rc" 1 "runner reports failure"
  assert_eq "$(jq -r '.state' < "$art/round-1/round.json")" "aborted" "round aborted"
  [[ -d "$art/round-1" ]] || pr_fail "round dir preserved for diagnosis"
}

test_nonzero_exit_with_output_counts_as_success() {
  local d art; d="$(pr_test_tmpdir)"; make_target "$d/target"
  run_round "$d/target" "$d/cache" "agent=$FAKES/fake-exit2-with-output.sh" > /dev/null 2>&1
  art="$(ls -d "$d/target/.plan-review/"*/)"
  assert_eq "$(jq -r '.reviewers.agent.status' < "$art/round-1/round.json")" "ok" "exit 2 tolerated"
  assert_eq "$(jq -r '.reviewers.agent.verdict' < "$art/round-1/round.json")" "BLOCKING" "verdict read"
}

test_missing_verdict_surfaces_as_unparseable() {
  local d art; d="$(pr_test_tmpdir)"; make_target "$d/target"
  run_round "$d/target" "$d/cache" "codex=$FAKES/fake-noverdict.sh" > /dev/null 2>&1
  art="$(ls -d "$d/target/.plan-review/"*/)"
  assert_eq "$(jq -r '.reviewers.codex.verdict' < "$art/round-1/round.json")" "UNPARSEABLE" "surfaced"
  assert_eq "$(jq -r '.reviewers.codex.status' < "$art/round-1/round.json")" "ok" "still usable output"
}

# Asserts the grandchild is GONE, by pid. Checking for the absence of a marker
# file the grandchild writes after 300s would pass whether or not it survived,
# because the test finishes first.
test_timeout_reaps_the_whole_process_group() {
  local d art pidfile child_pid; d="$(pr_test_tmpdir)"; make_target "$d/target"
  pidfile="$d/child.pid"
  PR_TEST_CHILD_PIDFILE="$pidfile" PR_TIMEOUT_SECS=3 PR_KILL_GRACE_SECS=2 \
    run_round "$d/target" "$d/cache" "codex=$FAKES/fake-slow-with-child.sh" > /dev/null 2>&1
  art="$(ls -d "$d/target/.plan-review/"*/)"
  assert_eq "$(jq -r '.reviewers.codex.status' < "$art/round-1/round.json")" "failed" "timed out"
  assert_contains "$(jq -r '.reviewers.codex.detail' < "$art/round-1/round.json")" "timed out" "reason"

  assert_file_exists "$pidfile" "fake adapter recorded its grandchild pid"
  assert_pid_gone "$(cat "$pidfile")" "grandchild survived the timeout; the process group was not reaped"
}

# The companion to the case above, for the adapter shape that defeats
# --kill-after: a child that handles TERM and exits, leaving a grandchild that
# ignores it. Measured 2026-08-19 -- rc=124 after 1s, grandchild alive 5s later.
test_timeout_reaps_descendants_of_a_polite_adapter() {
  local d art pidfile child_pid; d="$(pr_test_tmpdir)"; make_target "$d/target"
  pidfile="$d/child.pid"
  PR_TEST_CHILD_PIDFILE="$pidfile" PR_TIMEOUT_SECS=3 PR_KILL_GRACE_SECS=2 \
    run_round "$d/target" "$d/cache" \
    "codex=$FAKES/fake-term-handling-with-child.sh" > /dev/null 2>&1
  art="$(ls -d "$d/target/.plan-review/"*/)"
  assert_contains "$(jq -r '.reviewers.codex.detail' < "$art/round-1/round.json")" \
    "timed out" "recorded as a timeout"

  assert_file_exists "$pidfile" "the fake adapter recorded its grandchild pid"
  assert_pid_gone "$(cat "$pidfile")" "grandchild outlived its adapter; the group was not swept"
}

test_status_file_records_progress_events() {
  local d art; d="$(pr_test_tmpdir)"; make_target "$d/target"
  run_round "$d/target" "$d/cache" "codex=$FAKES/fake-ok.sh" > /dev/null 2>&1
  art="$(ls -d "$d/target/.plan-review/"*/)"
  assert_file_exists "$art/round-1/status.jsonl" "status file"
  assert_contains "$(cat "$art/round-1/status.jsonl")" '"state":"started"' "start event"
  assert_contains "$(cat "$art/round-1/status.jsonl")" '"state":"finished"' "finish event"
}

test_target_working_tree_is_untouched_apart_from_gitignored_artifacts() {
  local d before after; d="$(pr_test_tmpdir)"; make_target "$d/target"
  printf '.plan-review/\n' > "$d/target/.gitignore"
  git -C "$d/target" add -A && git -C "$d/target" commit -qm ignore
  before="$(git -C "$d/target" status --porcelain)"
  run_round "$d/target" "$d/cache" "codex=$FAKES/fake-ok.sh" > /dev/null 2>&1
  after="$(git -C "$d/target" status --porcelain)"
  assert_eq "$after" "$before" "US-4: working tree unchanged"
}

test_round_two_snapshots_a_diff_and_resumes_sessions() {
  local d art; d="$(pr_test_tmpdir)"; make_target "$d/target"
  run_round "$d/target" "$d/cache" "codex=$FAKES/fake-ok.sh" > /dev/null 2>&1
  art="$(ls -d "$d/target/.plan-review/"*/)"
  complete_round "$art/round-1"
  printf '# Plan\n\nDo the thing, but better.\n' > "$d/target/docs/plan.md"
  run_round "$d/target" "$d/cache" "codex=$FAKES/fake-ok.sh" > /dev/null 2>&1
  assert_file_exists "$art/round-2/plan.diff" "diff written"
  assert_contains "$(cat "$art/round-2/plan.diff")" "but better" "diff has the change"
  assert_contains "$(cat "$art/round-2/review-codex.md")" "resumed_from=fake-session" "resumed"
}

# --fresh drops the resume handles. It must NOT renumber or delete anything:
# US-11 promises every prior round stays readable.
test_fresh_discards_session_handles_without_destroying_history() {
  local d art; d="$(pr_test_tmpdir)"; make_target "$d/target"
  run_round "$d/target" "$d/cache" "codex=$FAKES/fake-ok.sh" > /dev/null 2>&1
  art="$(ls -d "$d/target/.plan-review/"*/)"
  complete_round "$art/round-1"

  PR_CACHE_ROOT="$d/cache" PR_ADAPTER_MAP="codex=$FAKES/fake-ok.sh" PR_ORCHESTRATOR=none \
    bash "$RUNNER" round --repo "$d/target" --plan docs/plan.md --fresh > /dev/null 2>&1

  assert_file_exists "$art/round-1/review-codex.md" "round 1 survives --fresh"
  assert_file_exists "$art/round-2/review-codex.md" "fresh round is round 2, not a re-used 1"
  assert_contains "$(cat "$art/round-2/review-codex.md")" "resumed_from=NONE" "handles dropped"
  assert_eq "$(jq -r '.fresh' < "$art/round-2/round.json")" "true" "baseline marked"
  assert_eq "$(jq -r '.fresh' < "$art/round-1/round.json")" "false" "round 1 not a baseline"
}

# An aborted predecessor forces --fresh, whatever aborted it -- including this
# routine all-reviewers-failed case, whose handles R1 already forfeited. The
# policy is one sentence: aborted means "this round did not finish, resume
# nothing from it". Enforced here since 2026-08-27; before that, README prose
# alone carried the obligation and nothing detected the condition.
test_an_aborted_predecessor_refuses_the_next_round_without_fresh() {
  local d art out rc; d="$(pr_test_tmpdir)"; make_target "$d/target"
  run_round "$d/target" "$d/cache" "codex=$FAKES/fake-fail.sh" > /dev/null 2>&1
  art="$(ls -d "$d/target/.plan-review/"*/)"
  assert_eq "$(jq -r '.state' < "$art/round-1/round.json")" "aborted" \
    "precondition: the all-failed round marked itself aborted"
  out="$(run_round "$d/target" "$d/cache" "codex=$FAKES/fake-ok.sh" 2>&1)"; rc=$?
  assert_exit_code "$rc" 2 "refused"
  assert_contains "$out" "--fresh" "the message names the remedy"
  assert_file_missing "$art/round-2" "no round was started"
}

test_fresh_starts_over_an_aborted_predecessor() {
  local d art rc=0; d="$(pr_test_tmpdir)"; make_target "$d/target"
  run_round "$d/target" "$d/cache" "codex=$FAKES/fake-fail.sh" > /dev/null 2>&1
  art="$(ls -d "$d/target/.plan-review/"*/)"
  PR_CACHE_ROOT="$d/cache" PR_ADAPTER_MAP="codex=$FAKES/fake-ok.sh" \
  PR_ORCHESTRATOR=none \
    bash "$RUNNER" round --repo "$d/target" --plan docs/plan.md --fresh \
    > /dev/null 2>&1 || rc=$?
  assert_exit_code "$rc" 0 "--fresh is the sanctioned path past an aborted round"
  assert_eq "$(jq -r '.fresh' < "$art/round-2/round.json")" "true" "and is a baseline"
}

# The fourth accepted cost of the one-sentence rule, pinned on purpose.
# `aborted` is reachable three ways; on this one R1 has forfeited nothing. The
# round finished cleanly, pr_session_set stored a good handle for every
# reviewer, and the operator then abandoned it with `abort` -- and the gate
# forfeits those handles anyway, plus the diff/critique/rationale --fresh also
# omits. That is deliberate: telling this path apart would need the round to
# record that its serial pass completed, the marker design the spec rejected
# (docs/process/brainstorm/2026-08-27-backlog-clearing-2.md). So a future
# reader who finds this strict should change the policy on purpose, not
# "fix" the predicate and delete this test.
test_an_abandoned_round_also_forces_fresh_though_its_handles_are_good() {
  local d art out rc=0 fresh_rc=0; d="$(pr_test_tmpdir)"; make_target "$d/target"
  run_round "$d/target" "$d/cache" "codex=$FAKES/fake-ok.sh" > /dev/null 2>&1
  art="$(ls -d "$d/target/.plan-review/"*/)"
  assert_eq "$(jq -r '.state' < "$art/round-1/round.json")" "awaiting_integration" \
    "precondition: the round finished cleanly"
  assert_contains "$(cat "$art/session-map.json")" "fake-session-" \
    "precondition: the clean reviewer's handle was stored and is good"
  bash "$RUNNER" abort --round "$art/round-1" > /dev/null 2>&1
  assert_eq "$(jq -r '.state' < "$art/round-1/round.json")" "aborted" \
    "precondition: abandoned, not failed"
  out="$(run_round "$d/target" "$d/cache" "codex=$FAKES/fake-ok.sh" 2>&1)"; rc=$?
  assert_exit_code "$rc" 2 "refused although nothing had forfeited the handles"
  assert_contains "$out" "--fresh" "the message names the remedy"
  assert_file_missing "$art/round-2" "no round was started"
  PR_CACHE_ROOT="$d/cache" PR_ADAPTER_MAP="codex=$FAKES/fake-ok.sh" \
  PR_ORCHESTRATOR=none \
    bash "$RUNNER" round --repo "$d/target" --plan docs/plan.md --fresh \
    > /dev/null 2>&1 || fresh_rc=$?
  assert_exit_code "$fresh_rc" 0 "--fresh is the way through"
  assert_eq "$(jq -r '.fresh' < "$art/round-2/round.json")" "true" "and is a baseline"
}

# The other half of the gate: --fresh that cannot clear the map must not
# start reviewers that would resume from it. Reproduced on the unchecked
# clear (2026-08-27): a read-only session-map.json printed Permission denied,
# the status was ignored, the round exited 0 with fresh:true, and the
# reviewer resumed from the old handle.
test_a_fresh_that_cannot_clear_the_map_starts_nothing() {
  (( EUID != 0 )) || { pr_test_skip "root writes anywhere; the case cannot exist"; return 0; }
  local d art out rc before; d="$(pr_test_tmpdir)"; make_target "$d/target"
  run_round "$d/target" "$d/cache" "codex=$FAKES/fake-ok.sh" > /dev/null 2>&1
  art="$(ls -d "$d/target/.plan-review/"*/)"
  complete_round "$art/round-1" > /dev/null
  before="$(cat "$art/session-map.json")"
  chmod a-w "$art/session-map.json"
  out="$(PR_CACHE_ROOT="$d/cache" PR_ADAPTER_MAP="codex=$FAKES/fake-ok.sh" \
    PR_ORCHESTRATOR=none \
    bash "$RUNNER" round --repo "$d/target" --plan docs/plan.md --fresh 2>&1)"; rc=$?
  chmod u+w "$art/session-map.json"
  assert_exit_code "$rc" 2 "a --fresh that cannot clear the map is a hard abort"
  assert_contains "$out" "aborting" "with the store-loss vocabulary"
  assert_file_missing "$art/round-2" "no round directory was created"
  assert_eq "$(cat "$art/session-map.json")" "$before" "the old map is intact"
}

# Starting round N+1 while N still awaits integration would silently skip the
# rationale step, which is the whole point of the loop.
test_runner_refuses_to_start_while_the_previous_round_awaits_integration() {
  local d art rc out; d="$(pr_test_tmpdir)"; make_target "$d/target"
  run_round "$d/target" "$d/cache" "codex=$FAKES/fake-ok.sh" > /dev/null 2>&1
  art="$(ls -d "$d/target/.plan-review/"*/)"
  assert_eq "$(jq -r '.state' < "$art/round-1/round.json")" "awaiting_integration" "precondition"
  out="$(run_round "$d/target" "$d/cache" "codex=$FAKES/fake-ok.sh" 2>&1)"; rc=$?
  assert_exit_code "$rc" 2 "refused"
  assert_contains "$out" "awaiting_integration" "says why"
  assert_file_missing "$art/round-2" "no round started"
}

# The guard is an allow-list. `reviewing` means a previous run died mid-flight;
# burying it under a new round would lose the only record that it happened.
test_runner_refuses_to_start_over_an_unfinished_round() {
  local d art rc out; d="$(pr_test_tmpdir)"; make_target "$d/target"
  run_round "$d/target" "$d/cache" "codex=$FAKES/fake-ok.sh" > /dev/null 2>&1
  art="$(ls -d "$d/target/.plan-review/"*/)"
  jq '.state = "reviewing"' < "$art/round-1/round.json" > "$art/t" \
    && mv "$art/t" "$art/round-1/round.json"
  out="$(run_round "$d/target" "$d/cache" "codex=$FAKES/fake-ok.sh" 2>&1)"; rc=$?
  assert_exit_code "$rc" 2 "refused"
  assert_contains "$out" "reviewing" "names the offending state"
  assert_file_missing "$art/round-2" "no round started"
}

# A refused --fresh must leave the handles it was going to reset alone, or the
# error message costs you the sessions it just declined to use.
test_refused_fresh_does_not_clear_the_session_map() {
  local d art; d="$(pr_test_tmpdir)"; make_target "$d/target"
  run_round "$d/target" "$d/cache" "codex=$FAKES/fake-ok.sh" > /dev/null 2>&1
  art="$(ls -d "$d/target/.plan-review/"*/)"
  assert_eq "$(jq -r '.codex' < "$art/session-map.json")" "fake-session-repo" "precondition"
  PR_CACHE_ROOT="$d/cache" PR_ADAPTER_MAP="codex=$FAKES/fake-ok.sh" PR_ORCHESTRATOR=none \
    bash "$RUNNER" round --repo "$d/target" --plan docs/plan.md --fresh > /dev/null 2>&1
  assert_eq "$(jq -r '.codex' < "$art/session-map.json")" "fake-session-repo" "handle kept"
}

# A handle cannot be told apart from a crash, so failure forfeits it. Retaining
# it would fail that reviewer identically every round.
test_a_failed_reviewer_forfeits_its_session_handle() {
  local d art; d="$(pr_test_tmpdir)"; make_target "$d/target"
  run_round "$d/target" "$d/cache" "codex=$FAKES/fake-ok.sh" "agy=$FAKES/fake-ok.sh" \
    > /dev/null 2>&1
  art="$(ls -d "$d/target/.plan-review/"*/)"
  complete_round "$art/round-1"
  run_round "$d/target" "$d/cache" "codex=$FAKES/fake-fail.sh" "agy=$FAKES/fake-ok.sh" \
    > /dev/null 2>&1
  assert_eq "$(jq -r '.codex // "ABSENT"' < "$art/session-map.json")" "ABSENT" "dropped"
  assert_eq "$(jq -r '.agy' < "$art/session-map.json")" "fake-session-repo" "sibling kept"
}

# Regression for the tab-delimited record: `detail` is empty whenever a reviewer
# succeeds cleanly, and IFS whitespace collapsing shifted every later field left.
test_an_empty_detail_does_not_shift_the_other_fields() {
  local d art r; d="$(pr_test_tmpdir)"; make_target "$d/target"
  run_round "$d/target" "$d/cache" "codex=$FAKES/fake-ok.sh" > /dev/null 2>&1
  art="$(ls -d "$d/target/.plan-review/"*/)"
  r="$(jq -r '.reviewers.codex' < "$art/round-1/round.json")"
  assert_eq "$(jq -r '.detail' <<< "$r")" "" "detail empty on a clean success"
  assert_eq "$(jq -r '.verdict' <<< "$r")" "MINOR" "verdict did not land in detail"
  assert_eq "$(jq -r '.session_id' <<< "$r")" "fake-session-repo" "session did not shift"
  assert_eq "$(jq -r '.model' <<< "$r")" "fake-model-1" "model did not shift"
  assert_eq "$(jq -r '.effort' <<< "$r")" "fake-effort-high" "effort read from meta line 3"
  assert_eq "$(jq -r '.cli_version' <<< "$r")" "fake-cli-9.9" "cli version from meta line 4"
}

# `exit 143` from a script and death by SIGTERM are the same number through $?.
# The runner may name the signal the code is consistent with; it may not say the
# reviewer was killed, and it must not imply its own deadline was involved.
test_a_signal_shaped_exit_is_described_without_claiming_a_signal() {
  local d art detail; d="$(pr_test_tmpdir)"; make_target "$d/target"
  run_round "$d/target" "$d/cache" "codex=$FAKES/fake-exit143.sh" > /dev/null 2>&1
  art="$(ls -d "$d/target/.plan-review/"*/)"
  detail="$(jq -r '.reviewers.codex.detail' < "$art/round-1/round.json")"
  assert_contains "$detail" "exit 143 (consistent with SIGTERM)" "names the signal it matches"
  assert_contains "$detail" "deadline had not elapsed" "and rules out the runner's own timeout"
  assert_not_contains "$detail" "killed" "nothing here knows that it was killed"
  assert_eq "$(jq -r '.reviewers.codex.status' < "$art/round-1/round.json")" "failed" "still a failure"
}

# An ordinary non-zero exit carries no signal claim at all.
test_a_plain_exit_code_is_reported_plainly() {
  local d art; d="$(pr_test_tmpdir)"; make_target "$d/target"
  run_round "$d/target" "$d/cache" "codex=$FAKES/fake-fail.sh" > /dev/null 2>&1
  art="$(ls -d "$d/target/.plan-review/"*/)"
  assert_eq "$(jq -r '.reviewers.codex.detail' < "$art/round-1/round.json")" \
    "exit 1, no output" "unchanged: no adapter reason, no signal-shaped code"
}

# The adapter knows things the exit code cannot carry.
test_an_adapter_reason_becomes_the_detail() {
  local d art detail; d="$(pr_test_tmpdir)"; make_target "$d/target"
  run_round "$d/target" "$d/cache" "codex=$FAKES/fake-fail-with-reason.sh" > /dev/null 2>&1
  art="$(ls -d "$d/target/.plan-review/"*/)"
  detail="$(jq -r '.reviewers.codex.detail' < "$art/round-1/round.json")"
  assert_eq "$detail" "the vendor said no" "first line only, replacing the generic message"
  assert_file_missing "$art/round-1/.reason-codex" "scratch file cleaned up"
}

# A round can be `ok` and still worth explaining: a swapped model is recorded in
# round.json's model field, which nobody comparing verdicts has a reason to read.
test_a_reason_is_recorded_on_a_successful_round_too() {
  local d art; d="$(pr_test_tmpdir)"; make_target "$d/target"
  run_round "$d/target" "$d/cache" "agent=$FAKES/fake-ok-with-reason.sh" > /dev/null 2>&1
  art="$(ls -d "$d/target/.plan-review/"*/)"
  assert_eq "$(jq -r '.reviewers.agent.status' < "$art/round-1/round.json")" "ok" "still ok"
  assert_eq "$(jq -r '.reviewers.agent.detail' < "$art/round-1/round.json")" \
    "switched to fake-model-swapped mid-run" "and says what happened"
}

# agy is the one adapter that must re-pass the prompt through argv, so a prompt
# over MAX_ARG_STRLEN cannot be reviewed by it at all. Refusing after the rsync
# would copy an entire repository for a reviewer already known to be doomed.
#
# PR_SKIP_PREFLIGHT because this points the roster at the real adapter path,
# which the preflight would otherwise demand agy, bwrap and a pin for. The
# adapter itself is never reached — that is what the test asserts.
test_an_oversized_prompt_fails_agy_before_the_sandbox_copy() {
  local d art detail; d="$(pr_test_tmpdir)"; make_target "$d/target"
  yes 'padding padding padding padding padding padding' | head -4000 \
    >> "$d/target/docs/plan.md"
  PR_SKIP_PREFLIGHT=1 run_round "$d/target" "$d/cache" \
    "agy=$PR_ROOT/adapters/agy.sh" > /dev/null 2>&1
  art="$(ls -d "$d/target/.plan-review/"*/)"
  detail="$(jq -r '.reviewers.agy.detail' < "$art/round-1/round.json")"
  assert_eq "$(jq -r '.reviewers.agy.status' < "$art/round-1/round.json")" "failed" "refused"
  assert_contains "$detail" "argv cap" "says which limit"
  assert_file_missing "$d/cache" "no repo copy was made for it"
}

# --- the orchestrator is required, and only required -----------------------
#
# Both refusals happen before the artifact directory exists, which is what the
# assert_file_missing lines check. What is NOT refused any more is a roster
# containing the orchestrator's own adapter.

# run_round supplies PR_ORCHESTRATOR=none, so these call the runner directly.
run_round_as() {  # run_round_as <orchestrator-or-UNSET> <target> <cache> <map>
  local orch="$1" target="$2" cache="$3" map="$4"
  if [[ "$orch" == UNSET ]]; then
    env -u PR_ORCHESTRATOR PR_CACHE_ROOT="$cache" PR_ADAPTER_MAP="$map" \
      bash "$RUNNER" round --repo "$target" --plan docs/plan.md 2>&1
  else
    PR_ORCHESTRATOR="$orch" PR_CACHE_ROOT="$cache" PR_ADAPTER_MAP="$map" \
      bash "$RUNNER" round --repo "$target" --plan docs/plan.md 2>&1
  fi
}

test_an_unset_orchestrator_refuses_the_round() {
  local d out rc; d="$(pr_test_tmpdir)"; make_target "$d/target"
  out="$(run_round_as UNSET "$d/target" "$d/cache" "codex=$FAKES/fake-ok.sh")"; rc=$?
  assert_exit_code "$rc" 2 "a usage refusal, not a failed round"
  assert_contains "$out" "PR_ORCHESTRATOR is unset" "says what is missing"
  assert_file_missing "$d/target/.plan-review" "nothing was written"
}

test_an_unknown_orchestrator_refuses_the_round() {
  local d out rc; d="$(pr_test_tmpdir)"; make_target "$d/target"
  out="$(run_round_as cursor "$d/target" "$d/cache" "codex=$FAKES/fake-ok.sh")"; rc=$?
  assert_exit_code "$rc" 2 "a usage refusal"
  assert_contains "$out" "is not one of" "names the accepted values"
  assert_file_missing "$d/target/.plan-review" "nothing was written"
}

# The rule that used to refuse this is gone. A roster naming the orchestrator's
# own CLI runs, silently: the check tested CLI names, independence is lost on
# model identity, and the runner never learns the orchestrator's model. The
# reviewer here is a fake mounted under the key `claude`, which is exactly the
# case the old path-keyed check was careful NOT to refuse -- so the assertion is
# that a stated roster runs and records no warning about itself.
test_a_roster_containing_the_orchestrator_runs_and_warns_about_nothing() {
  local d art; d="$(pr_test_tmpdir)"; make_target "$d/target"
  PR_ORCHESTRATOR=claude run_round "$d/target" "$d/cache" \
    "claude=$FAKES/fake-ok.sh" > /dev/null 2>&1
  art="$(ls -d "$d/target/.plan-review/"*/)"
  assert_eq "$(jq -r '.reviewers.claude.status' < "$art/round-1/round.json")" "ok" \
    "the round ran"
  assert_eq "$(jq -r '.warnings | length' < "$art/round-1/round.json")" "0" \
    "and said nothing about self-review"
  assert_eq "$(jq -r '.orchestrator' < "$art/round-1/round.json")" "claude" \
    "the record of who drove it is what survives the deleted rule"
}

test_the_orchestrator_is_recorded_in_round_json() {
  local d art; d="$(pr_test_tmpdir)"; make_target "$d/target"
  PR_ORCHESTRATOR=codex run_round "$d/target" "$d/cache" \
    "agy=$FAKES/fake-ok.sh" > /dev/null 2>&1
  art="$(ls -d "$d/target/.plan-review/"*/)"
  assert_eq "$(jq -r '.orchestrator' < "$art/round-1/round.json")" "codex" \
    "who drove the round is part of the record"
}

# --- the project config, end to end ----------------------------------------
#
# The roster here still comes from PR_ADAPTER_MAP, because a config's reviewer
# list resolves to this repo's real adapters and those would run real CLIs. The
# list-to-map derivation is tested in tests/test-roster.sh; what these check is
# everything a config changes about a round that has already started.

write_config() {  # write_config <target> <json>
  mkdir -p "$1/.plan-review/prompts"
  printf 'House rule: start from the threat model.\n' > "$1/.plan-review/prompts/initial.md"
  printf 'House rule: say whether the objection stands.\n' > "$1/.plan-review/prompts/rereview.md"
  printf '%s\n' "$2" > "$1/.plan-review/config.json"
}

# A config lives in .plan-review/ too, so `ls -d .plan-review/*/` is no longer a
# way to find the session directory: it matches prompts/ as well.
artifact_dir() {
  local d; d="$(ls -d "$1"/.plan-review/*-docs--plan/ 2>/dev/null | head -1)"
  printf '%s' "${d%/}"   # ls -d's trailing slash otherwise doubles in every path
}

CFG_CRITERIA='{"criteria": {"initial": "prompts/initial.md",
                            "rereview": "prompts/rereview.md"},
               "pins": {"codex": {"model": "gpt-5.6-sol", "effort": "xhigh"}}}'

test_a_round_with_no_config_records_a_null_path_and_no_warnings() {
  local d art; d="$(pr_test_tmpdir)"; make_target "$d/target"
  run_round "$d/target" "$d/cache" "codex=$FAKES/fake-ok.sh" > /dev/null 2>&1
  art="$(artifact_dir "$d/target")"
  assert_eq "$(jq -r '.config.path' < "$art/round-1/round.json")" "null" "no config"
  assert_eq "$(jq -r '.warnings | length' < "$art/round-1/round.json")" "0" "and nothing to say"
  assert_file_missing "$art/round-1/criteria-initial.snapshot.md" "no criteria, no snapshot"
}

test_the_criteria_are_snapshotted_and_the_snapshot_is_what_reviewers_read() {
  local d art; d="$(pr_test_tmpdir)"; make_target "$d/target"
  write_config "$d/target" "$CFG_CRITERIA"
  run_round "$d/target" "$d/cache" "codex=$FAKES/fake-echo-prompt.sh" > /dev/null 2>&1
  art="$(artifact_dir "$d/target")"
  assert_file_exists "$art/round-1/criteria-initial.snapshot.md" "the slot in use"
  # Both slots, because the hash covers both: a hash over only the slot in use
  # would differ between round 1 and round 2 by construction.
  assert_file_exists "$art/round-1/criteria-rereview.snapshot.md" "and the one that is not"
  assert_contains "$(cat "$art/round-1/criteria-initial.snapshot.md")" \
    "start from the threat model" "the copy holds what the source held"

  # The assembled prompt is deleted with the round's other scratch files, so
  # what the reviewer received is only knowable from the reviewer's own output.
  assert_contains "$(cat "$art/round-1/review-codex.md")" "start from the threat model" \
    "and the reviewer was sent it"
  assert_not_contains "$(cat "$art/round-1/review-codex.md")" "objection stands" \
    "with the slot for the other round type left out"
}

test_the_resolved_config_is_recorded_with_per_field_provenance() {
  local d art rj; d="$(pr_test_tmpdir)"; make_target "$d/target"
  write_config "$d/target" "$CFG_CRITERIA"
  PR_CODEX_EFFORT=low run_round "$d/target" "$d/cache" "codex=$FAKES/fake-ok.sh" > /dev/null 2>&1
  art="$(artifact_dir "$d/target")"; rj="$art/round-1/round.json"
  assert_contains "$(jq -r '.config.path' < "$rj")" "config.json" "which file applied"
  assert_eq "$(jq -r '.config.pins.codex.model_source' < "$rj")" "config" "model from the file"
  assert_eq "$(jq -r '.config.pins.codex.effort' < "$rj")" "low" "effort from the environment"
  assert_eq "$(jq -r '.config.pins.codex.effort_source' < "$rj")" "env" "and it says so"
  assert_eq "$(jq -r '.config.criteria.initial' < "$rj")" "prompts/initial.md" "as written"
  [[ "$(jq -r '.config.sha256' < "$rj")" =~ ^[0-9a-f]{64}$ ]] \
    || pr_fail "a settings hash was recorded"
}

test_a_bad_effort_refuses_before_the_artifact_directory_exists() {
  local d out rc; d="$(pr_test_tmpdir)"; make_target "$d/target"
  out="$(PR_CODEX_EFFORT=hgih run_round "$d/target" "$d/cache" \
          "codex=$FAKES/fake-ok.sh" 2>&1)"; rc=$?
  assert_exit_code "$rc" 2 "refused, not attempted"
  assert_contains "$out" "is not one of" "names the enum"
  assert_file_missing "$d/target/.plan-review" "and left nothing behind"
}

# A rejected config lives in .plan-review/, so the directory cannot be absent.
# What must be absent is a session artifact directory for this plan.
test_a_rejected_config_creates_no_session_directory() {
  local d out rc; d="$(pr_test_tmpdir)"; make_target "$d/target"
  write_config "$d/target" '{"reviewrs": ["codex"]}'
  out="$(run_round "$d/target" "$d/cache" "codex=$FAKES/fake-ok.sh" 2>&1)"; rc=$?
  assert_exit_code "$rc" 2 "refused"
  assert_contains "$out" "unknown key" "and said why"
  assert_eq "$(artifact_dir "$d/target")" "" "no round directory was created"
  assert_file_exists "$d/target/.plan-review/config.json" "the config it rejected is untouched"
}

test_editing_a_criteria_file_between_history_rounds_warns_about_drift() {
  local d art; d="$(pr_test_tmpdir)"; make_target "$d/target"
  write_config "$d/target" "$CFG_CRITERIA"
  run_round "$d/target" "$d/cache" "codex=$FAKES/fake-ok.sh" > /dev/null 2>&1
  art="$(artifact_dir "$d/target")"
  complete_round "$art/round-1" > /dev/null

  printf 'And check the tests.\n' >> "$d/target/.plan-review/prompts/rereview.md"
  local out; out="$(run_round "$d/target" "$d/cache" "codex=$FAKES/fake-ok.sh" 2>&1)"
  assert_contains "$out" "configuration changed since round 1" "warned on stderr"
  assert_contains "$(jq -r '.warnings[0]' < "$art/round-2/round.json")" "consider --fresh" \
    "and kept in the artifact"
  assert_contains "$(cat "$art/round-1/criteria-rereview.snapshot.md")" "objection stands" \
    "round 1's copy still shows what round 1 was told"
}

test_an_unchanged_config_produces_no_drift_warning() {
  local d art out; d="$(pr_test_tmpdir)"; make_target "$d/target"
  write_config "$d/target" "$CFG_CRITERIA"
  run_round "$d/target" "$d/cache" "codex=$FAKES/fake-ok.sh" > /dev/null 2>&1
  art="$(artifact_dir "$d/target")"
  complete_round "$art/round-1" > /dev/null
  out="$(run_round "$d/target" "$d/cache" "codex=$FAKES/fake-ok.sh" 2>&1)"
  assert_not_contains "$out" "configuration changed" "the hash is stable across runs"
}

# A --fresh round has no carried-over context to be inconsistent with, so the
# warning there would be noise.
test_a_fresh_round_never_warns_about_drift() {
  local d art out; d="$(pr_test_tmpdir)"; make_target "$d/target"
  write_config "$d/target" "$CFG_CRITERIA"
  run_round "$d/target" "$d/cache" "codex=$FAKES/fake-ok.sh" > /dev/null 2>&1
  art="$(artifact_dir "$d/target")"
  complete_round "$art/round-1" > /dev/null
  printf 'And check the tests.\n' >> "$d/target/.plan-review/prompts/rereview.md"
  out="$(PR_CACHE_ROOT="$d/cache" PR_ADAPTER_MAP="codex=$FAKES/fake-ok.sh" \
         PR_ORCHESTRATOR=none PR_TIMEOUT_SECS=60 \
         bash "$RUNNER" round --repo "$d/target" --plan docs/plan.md --fresh 2>&1)"
  assert_not_contains "$out" "configuration changed" "nothing to be inconsistent with"
}

# --- the one post-round warning ---------------------------------------------

test_two_reviewers_on_the_same_recorded_model_warn_after_the_round() {
  local d art out; d="$(pr_test_tmpdir)"; make_target "$d/target"
  out="$(run_round "$d/target" "$d/cache" \
          "codex=$FAKES/fake-ok.sh" "agy=$FAKES/fake-ok.sh" 2>&1)"
  art="$(artifact_dir "$d/target")"
  assert_contains "$out" "recorded the same model" "one perspective bought twice"
  assert_contains "$(jq -r '.warnings[0]' < "$art/round-1/round.json")" "agy and codex" \
    "both named, in the artifact"
}

# Two failures both recording "" are two absences, not a duplicate perspective,
# and the round has already failed loudly.
test_two_failed_reviewers_are_not_a_duplicate_model() {
  local d art; d="$(pr_test_tmpdir)"; make_target "$d/target"
  run_round "$d/target" "$d/cache" \
    "codex=$FAKES/fake-fail.sh" "agy=$FAKES/fake-fail.sh" > /dev/null 2>&1
  art="$(artifact_dir "$d/target")"
  assert_eq "$(jq -r '.warnings | length' < "$art/round-1/round.json")" "0" \
    "no warning about two absent models"
}

# --- the session lock -------------------------------------------------------

# Round selection is a read-then-create with no atomicity of its own: two
# invocations could both compute round 4 and both mkdir it. The lock is what
# stops that, and the pid in the refusal is what tells the operator to wait.
test_a_second_round_on_the_same_plan_is_refused_while_the_first_runs() {
  local d art out rc; d="$(pr_test_tmpdir)"; make_target "$d/target"
  start_held_round "$d/target" "$d/cache" "$d/hold" "$d/adapter.pid"

  out="$(PR_LOCK_WAIT_SECS=0.1 PR_CACHE_ROOT="$d/cache" \
         PR_ADAPTER_MAP="codex=$FAKES/fake-ok.sh" PR_ORCHESTRATOR=none \
         bash "$RUNNER" round --repo "$d/target" --plan docs/plan.md 2>&1)"; rc=$?
  art="$(ls -d "$d/target/.plan-review/"*/)"; art="${art%/}"

  assert_exit_code "$rc" 2 "refused, having started nothing"
  assert_contains "$out" "already running" "says what is in the way"
  # 7a: a waiter that opened the lock with `>` would have truncated this away.
  assert_contains "$out" "$PR_TEST_ROUND" "names the runner that holds the session"
  assert_file_missing "$art/round-2" "and no second round directory was created"

  rm -f "$d/hold"
  wait "$PR_TEST_ROUND" 2> /dev/null
  assert_eq "$(jq -r '.state' < "$art/round-1/round.json")" "awaiting_integration" \
    "the first round finished undisturbed"
}

# The runner holds the lock by the time it reads the previous round's state, so
# it can say more than the doctor can: nothing survived, or the lock would not
# have been free.
test_a_stuck_round_is_reported_with_the_command_that_clears_it() {
  local d art out rc; d="$(pr_test_tmpdir)"; make_target "$d/target"
  run_round "$d/target" "$d/cache" "codex=$FAKES/fake-ok.sh" > /dev/null 2>&1
  art="$(ls -d "$d/target/.plan-review/"*/)"; art="${art%/}"
  jq '.state = "reviewing"' < "$art/round-1/round.json" > "$art/t" \
    && mv "$art/t" "$art/round-1/round.json"

  out="$(run_round "$d/target" "$d/cache" "codex=$FAKES/fake-ok.sh" 2>&1)"; rc=$?
  assert_exit_code "$rc" 2 "blocked"
  assert_contains "$out" "Nothing is running" "distinguishes dead from busy"
  assert_contains "$out" "plan-review abort --round $art/round-1" "an executable remedy"
  assert_not_contains "$out" "jq '.state" "no hand-typed mutation of a file we own"
}

# An unwritable session directory must never be reported as another round
# running: that sends the operator away to wait for something that will never
# finish.
test_a_lock_that_cannot_be_opened_is_not_reported_as_a_busy_session() {
  local d key art out rc; d="$(pr_test_tmpdir)"; make_target "$d/target"
  [[ "$EUID" -ne 0 ]] || return 0   # root opens anything; the case cannot exist
  key="$(pr_session_key "$(cd "$d/target" && pwd)" docs/plan.md)"
  art="$d/target/.plan-review/$key"
  mkdir -p "$art"
  chmod 000 "$art"
  out="$(run_round "$d/target" "$d/cache" "codex=$FAKES/fake-ok.sh" 2>&1)"; rc=$?
  chmod 700 "$art"
  assert_exit_code "$rc" 2 "refused"
  assert_contains "$out" "could not open the session lock" "names the real failure"
  assert_not_contains "$out" "already running" "and never blames a phantom round"
}

# Starts from a STORED handle and proves it is deleted. Asserting that no new
# handle was written would pass against the bug: pr_session_set ignores an empty
# id on purpose, so the stale one would survive silently.
test_a_timed_out_reviewer_forfeits_its_stored_handle() {
  local d key art; d="$(pr_test_tmpdir)"; make_target "$d/target"
  key="$(pr_session_key "$(cd "$d/target" && pwd)" docs/plan.md)"
  art="$(pr_artifact_dir "$(cd "$d/target" && pwd)" "$key")"
  mkdir -p "$art"
  echo '{"codex":"handle-from-an-earlier-round"}' > "$art/session-map.json"

  PR_TIMEOUT_SECS=2 PR_KILL_GRACE_SECS=1 \
    run_round "$d/target" "$d/cache" \
    "codex=$FAKES/fake-slow-with-output.sh" > /dev/null 2>&1

  assert_eq "$(jq -r '.reviewers.codex.status' < "$art/round-1/round.json")" "ok" \
    "partial output is still kept and still ok"
  assert_eq "$(jq -r '.codex // "GONE"' < "$art/session-map.json")" "GONE" \
    "the stale handle was retired"
}

# --- sandbox retention ------------------------------------------------------

test_a_clean_reviewer_loses_its_repo_copy_and_keeps_its_config() {
  local d art key; d="$(pr_test_tmpdir)"; make_target "$d/target"
  key="$(pr_session_key "$(cd "$d/target" && pwd)" docs/plan.md)"
  mkdir -p "$d/cache/$key/codex/config"
  echo state > "$d/cache/$key/codex/config/sessions.json"
  run_round "$d/target" "$d/cache" "codex=$FAKES/fake-ok.sh" > /dev/null 2>&1
  art="$(ls -d "$d/target/.plan-review/"*/)"
  assert_file_exists "$art/round-1/review-codex.md" "the round ran"
  assert_file_missing "$d/cache/$key/codex/repo" "the copy is gone"
  assert_file_exists "$d/cache/$key/codex/config/sessions.json" "the resume state is not"
}

# `status == ok` is not "finished cleanly": Cursor exits 2 on a denied tool call
# while still producing a correct review, and a timed-out reviewer's partial
# output is kept precisely so its tree can be read.
test_anything_abnormal_keeps_its_repo_copy() {
  local d key; d="$(pr_test_tmpdir)"; make_target "$d/target"
  key="$(pr_session_key "$(cd "$d/target" && pwd)" docs/plan.md)"
  PR_TIMEOUT_SECS=1 run_round "$d/target" "$d/cache" \
    "codex=$FAKES/fake-ok.sh" \
    "agent=$FAKES/fake-exit2-with-output.sh" \
    "agy=$FAKES/fake-fail.sh" \
    "claude=$FAKES/fake-slow-with-child.sh" > /dev/null 2>&1
  assert_file_missing "$d/cache/$key/codex/repo" "the clean one's copy is gone"
  [[ -d "$d/cache/$key/agent/repo" ]] || pr_fail "a non-zero exit keeps its copy"
  [[ -d "$d/cache/$key/agy/repo" ]] || pr_fail "a failure keeps its copy"
  [[ -d "$d/cache/$key/claude/repo" ]] || pr_fail "a timeout keeps its copy"
}

test_keep_sandbox_keeps_everything() {
  local d key; d="$(pr_test_tmpdir)"; make_target "$d/target"
  key="$(pr_session_key "$(cd "$d/target" && pwd)" docs/plan.md)"
  PR_KEEP_SANDBOX=1 run_round "$d/target" "$d/cache" "codex=$FAKES/fake-ok.sh" \
    > /dev/null 2>&1
  [[ -d "$d/cache/$key/codex/repo" ]] || pr_fail "PR_KEEP_SANDBOX=1 kept nothing"
}

# Housekeeping is never a verdict on the round: three good reviews must not be
# reported broken because a temp copy would not delete.
test_a_failed_discard_warns_without_failing_the_round() {
  local d art rc out; d="$(pr_test_tmpdir)"; make_target "$d/target"
  [[ "$EUID" -ne 0 ]] || return 0   # root removes anything; the case cannot exist
  out="$(run_round "$d/target" "$d/cache" "codex=$FAKES/fake-ok-locks-sandbox.sh" 2>&1)"
  rc=$?
  art="$(ls -d "$d/target/.plan-review/"*/)"
  assert_exit_code "$rc" 0 "the round still succeeded"
  assert_eq "$(jq -r '.state' < "$art/round-1/round.json")" "awaiting_integration" "and finished"
  assert_contains "$out" "could not discard the sandbox copy" "but said so"
  assert_contains "$(jq -r '.warnings | join(" ")' < "$art/round-1/round.json")" \
    "could not discard" "and recorded it in the artifact"
}

# The child's meta read is guarded (-f, so a symlink to a device or a FIFO is
# skipped) and bounded (head -c 4096). Measured unguarded (2026-08-27): the
# device symlink ballooned the child past 3GB RSS with no deadline over it,
# and the writer-less FIFO blocked forever at open(2). The outer timeout is
# why a regression fails red here instead of hanging the suite -- though the
# symlink case's failure mode is memory, not time: if this goes red, check
# for a leaked child before rerunning.
test_a_meta_swapped_for_a_device_symlink_reads_as_empty_meta() {
  pr_test_requires /dev/zero || return 0
  local d art rc=0; d="$(pr_test_tmpdir)"; make_target "$d/target"
  PR_CACHE_ROOT="$d/cache" PR_ADAPTER_MAP="codex=$FAKES/fake-ok-meta-symlink.sh" \
  PR_TIMEOUT_SECS=10 PR_ORCHESTRATOR=none \
    timeout 30 bash "$RUNNER" round --repo "$d/target" --plan docs/plan.md \
    > /dev/null 2>&1 || rc=$?
  assert_exit_code "$rc" 0 "the round completed despite the hostile meta"
  art="$(ls -d "$d/target/.plan-review/"*/)"
  assert_eq "$(jq -r '.state' < "$art/round-1/round.json")" "awaiting_integration" \
    "and finished"
  assert_eq "$(jq -r '.reviewers.codex.model' < "$art/round-1/round.json")" "" \
    "no meta line was read from the device"
}

test_a_meta_swapped_for_a_writerless_fifo_reads_as_empty_meta() {
  pr_test_requires mkfifo || return 0
  local d art rc=0; d="$(pr_test_tmpdir)"; make_target "$d/target"
  PR_CACHE_ROOT="$d/cache" PR_ADAPTER_MAP="codex=$FAKES/fake-ok-meta-fifo.sh" \
  PR_TIMEOUT_SECS=10 PR_ORCHESTRATOR=none \
    timeout 30 bash "$RUNNER" round --repo "$d/target" --plan docs/plan.md \
    > /dev/null 2>&1 || rc=$?
  assert_exit_code "$rc" 0 "the round completed; the -f guard skipped the FIFO"
  art="$(ls -d "$d/target/.plan-review/"*/)"
  assert_eq "$(jq -r '.reviewers.codex.session_id' < "$art/round-1/round.json")" "" \
    "no session handle was read from the FIFO"
}

# The bound itself, on a regular file the -f guard waves through: 8192 bytes
# in, exactly 4096 recorded. The symlink and FIFO cases cannot pin this --
# they never reach the read -- so dropping head -c while keeping -f would
# leave them green; this one goes red.
test_an_oversize_meta_is_cut_at_the_4096_byte_bound() {
  local d art rc=0; d="$(pr_test_tmpdir)"; make_target "$d/target"
  PR_CACHE_ROOT="$d/cache" PR_ADAPTER_MAP="codex=$FAKES/fake-ok-meta-oversize.sh" \
  PR_TIMEOUT_SECS=10 PR_ORCHESTRATOR=none \
    timeout 30 bash "$RUNNER" round --repo "$d/target" --plan docs/plan.md \
    > /dev/null 2>&1 || rc=$?
  assert_exit_code "$rc" 0 "oversize gibberish lands where undersize gibberish does"
  art="$(ls -d "$d/target/.plan-review/"*/)"
  assert_eq "$(jq -r '.reviewers.codex.session_id | length' < "$art/round-1/round.json")" \
    "4096" "the recorded line is the first 4096 bytes, no more"
}

# Loss of the artifact store: the parent aborts hard with the error on stderr
# rather than reaching awaiting_integration with an artifact it could not write.
#
# Measured before the guards (2026-08-26), with a second, healthy reviewer
# alongside this one: the round printed "Round 1 complete" and exited 0 over a
# round.json that still read {"state":"reviewing","reviewers":{}} while
# review-codex.md sat beside it on disk.
test_a_read_only_round_dir_aborts_hard() {
  local d out rc=0; d="$(pr_test_tmpdir)"; make_target "$d/target"
  out="$(run_round "$d/target" "$d/cache" \
    "codex=$FAKES/fake-ok-locks-artifacts.sh" 2>&1)" || rc=$?
  # put the tree back before asserting, so a failure here cannot strand a
  # read-only directory past this test (pr_run_tests chmods the tmproot too).
  chmod -R u+w "$d/target/.plan-review" 2> /dev/null
  assert_exit_code "$rc" 2 "store loss is a hard abort, not a completed round"
  assert_contains "$out" "aborting" "with the error on stderr"
  # Positive, not `assert_not_contains awaiting_integration`: an absent
  # round.json would satisfy the negative form vacuously.
  assert_eq "$(jq -r .state "$d/target/.plan-review"/*/round-1/round.json)" \
    reviewing "the round never claims a state it could not record"
}

# The late-failure half of unit A: everything succeeds except the final
# .state = awaiting_integration edit. The guard lives at the call site in
# libexec/plan-review-round.sh, and this test reaches it through the real
# runner -- "Round complete" must not print over a state that never persisted.
#
# The seam is a PATH shim over jq that delegates every call except the one
# carrying `awaiting_integration`: only pr_round_set_state's terminal edit ever
# passes that string, so the reviewer records and the session map go through
# untouched and the round reaches its final write intact.
test_a_failed_terminal_state_write_aborts_hard() {
  local d out rc=0; d="$(pr_test_tmpdir)"; make_target "$d/target"
  mkdir -p "$d/bin"
  pr_test_mkstub "$d/bin/jq" 'for a in "$@"; do [[ "$a" == *awaiting_integration* ]] && exit 1; done
exec '"$(command -v jq)"' "$@"'
  out="$(PATH="$d/bin:$PATH" run_round "$d/target" "$d/cache" \
    "codex=$FAKES/fake-ok.sh" 2>&1)" || rc=$?
  assert_exit_code "$rc" 2 "a terminal state the store refused is a hard abort"
  assert_not_contains "$out" "Round complete" "no completion claim without the write"
  assert_eq "$(jq -r .state "$d/target/.plan-review"/*/round-1/round.json)" \
    reviewing "the state on disk is the last one actually written"
}

pr_run_tests

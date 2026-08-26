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
  assert_eq "$(< "$status_file")" "" "nothing spawned: no status event"
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

# Publication: every semantic read comes from an immutable copy, so a survivor
# still holding the scratch inode cannot change what the round recorded. Not an
# instantaneous snapshot -- a torn tail during the copy is accepted, because
# every downstream read uses the same copy (spec glossary, "Publication").
test_publication_makes_the_review_immune_to_later_scratch_writes() {
  local d; d="$(pr_test_tmpdir)"
  setup_session "$d"
  pr_reviewer_run_all "codex=$FAKES/fake-ok.sh"
  assert_file_exists "$round_dir/review-codex.md" "the review was published"
  local before; before="$(< "$round_dir/review-codex.md")"
  # The load-bearing assertion, and the only one that separates publication
  # from doing nothing at all: without publication the adapter writes
  # review-codex.md itself and the append below creates a scratch file nobody
  # reads, so the other three assertions pass over an unimplemented feature.
  # It is equally what distinguishes cp+mv from a bare `mv`, which would leave
  # no scratch behind -- and a bare mv is exactly the implementation this
  # change exists to prevent, because a survivor holding the open scratch fd
  # would then be writing into the PUBLISHED inode.
  assert_file_exists "$round_dir/.review-codex.scratch" \
    "the adapter wrote to scratch, and publication copied rather than moved it"
  echo "TAINT from a survivor" >> "$round_dir/.review-codex.scratch"
  assert_eq "$(< "$round_dir/review-codex.md")" "$before" \
    "the published review is the publication-time copy"
  assert_eq "$(jq -r .verdict < "$round_dir/.result-codex")" \
    "$(pr_parse_verdict "$round_dir/review-codex.md")" \
    "the record and the published file describe the same bytes"
}

# A failed publication is a reviewer failure -- a new critical write, checked
# here rather than deferred to the write-integrity unit.
test_a_failed_publication_is_a_reviewer_failure() {
  local d; d="$(pr_test_tmpdir)"
  setup_session "$d"
  # A dangling symlink at the publication temp path makes the copy fail
  # deterministically without touching anything else in the round directory.
  ln -s "$round_dir/no-such-dir/x" "$round_dir/review-codex.md.publish"
  pr_reviewer_run_all "codex=$FAKES/fake-ok.sh"
  local status session discard timed_out
  pr_reviewer_result_read codex status session discard timed_out
  assert_eq "$status" failed "publication failure fails the reviewer"
  assert_contains "$(jq -r .detail < "$round_dir/.result-codex")" \
    "publication" "and the detail says why"
  assert_file_missing "$round_dir/review-codex.md" "nothing was published"
  # The record still carries the facts the child had in hand. Without this the
  # eight-argument call defaults timed_out to false and blanks all four meta
  # lines, so round.json would report a reviewer that timed out as on time and
  # the duplicate-model warning could not see its model.
  assert_eq "$(jq -r '.model, .cli | tostring' < "$round_dir/.result-codex" | tr '\n' ' ')" \
    "fake-model-1 fake-cli-9.9 " "the meta the adapter wrote survives the failure"
}

# The module boundary: the round reaches the record through the accessor and
# deletes nothing itself, so a rename inside this module cannot silently break
# the round (BACKLOG 2026-08-26, /simplify).
test_the_runner_owns_its_scratch_names() {
  local d; d="$(pr_test_tmpdir)"
  setup_session "$d"
  pr_reviewer_run_all "codex=$FAKES/fake-ok.sh"
  assert_file_exists "$(pr_reviewer_result_path codex)" "the accessor finds the record"
  pr_reviewer_scratch_rm codex
  assert_file_missing "$round_dir/.result-codex"  "record swept"
  assert_file_missing "$round_dir/.meta-codex"    "meta swept"
  assert_file_missing "$round_dir/.reason-codex"  "reason swept"
  assert_file_missing "$round_dir/.prompt-codex.txt" "prompt swept"
  assert_file_missing "$round_dir/.review-codex.scratch" "review scratch swept"
  assert_file_exists  "$round_dir/review-codex.md" "the published review is not scratch"
}

# --- write integrity: the child guards ---------------------------------------

# A reviewer that cannot be given its prompt must be refused, not fed empty
# stdin. /dev/full through a symlink is the seam: opening succeeds, writing
# fails, and -s on it is false -- no production hook needed.
#
# Measured on the unguarded code (2026-08-26): /dev/full is not merely an
# unwritable file, it READS as an endless stream of NULs, so the adapter was
# spawned and handed 64 zero bytes where the plan should have been, wrote a
# review of nothing, and the round recorded it ok/MINOR. "Empty stdin" was the
# optimistic reading of this path.
test_a_failed_prompt_write_refuses_to_spawn_the_adapter() {
  pr_test_requires /dev/full || return 0
  local d; d="$(pr_test_tmpdir)"
  setup_session "$d"
  ln -s /dev/full "$round_dir/.prompt-codex.txt"
  pr_reviewer_run_all "codex=$FAKES/fake-echo-prompt.sh"
  local status session discard timed_out
  pr_reviewer_result_read codex status session discard timed_out
  assert_eq "$status" failed "no prompt, no spawn"
  assert_contains "$(jq -r .detail < "$round_dir/.result-codex")" "prompt" \
    "the detail names the prompt write"
  assert_file_missing "$round_dir/.review-codex.scratch" "the adapter never ran"
}

# Measured on the unguarded code: an unwritable meta pre-seed did not merely
# lose the pre-seed -- the child then read the same /dev/full back with
# `mapfile`, grew past 3GB RSS in twelve seconds and never returned, under no
# deadline (the kernel's timeout covers the adapter, not this read). The guard
# below is what keeps that read from ever being reached.
#
# So if you revert that guard, this case does not FAIL -- it eats the machine.
# Expect an unbounded child, not a red assertion, and kill it by process group.
test_a_failed_meta_preseed_is_a_reviewer_failure() {
  pr_test_requires /dev/full || return 0
  local d; d="$(pr_test_tmpdir)"
  setup_session "$d"
  ln -s /dev/full "$round_dir/.meta-codex"
  pr_reviewer_run_all "codex=$FAKES/fake-ok.sh"
  local status session discard timed_out
  pr_reviewer_result_read codex status session discard timed_out
  assert_eq "$status" failed "a meta pre-seed that cannot be written fails the reviewer"
}

# --- write integrity: the parent's synthesis ---------------------------------

test_ensure_synthesizes_a_missing_record() {
  local d; d="$(pr_test_tmpdir)"
  setup_session "$d"
  pr_reviewer_result_ensure ghost; local rc=$?
  assert_exit_code "$rc" 1 "missing record reported as synthesized"
  assert_eq "$(jq -r .status < "$round_dir/.result-ghost")" failed "synthesized failed"
  assert_contains "$(jq -r .detail < "$round_dir/.result-ghost")" "record missing" \
    "missing and invalid carry different details"
}

test_ensure_synthesizes_an_invalid_record() {
  local d; d="$(pr_test_tmpdir)"
  setup_session "$d"
  echo 'not json at all' > "$round_dir/.result-broken"
  pr_reviewer_result_ensure broken; local rc=$?
  assert_exit_code "$rc" 1 "invalid record reported as synthesized"
  assert_contains "$(jq -r .detail < "$round_dir/.result-broken")" "record invalid" \
    "the diagnosis differs from missing"
}

# Domain, not just shape: all nine fields present and typed, but a status
# outside {ok, failed} must still be refused -- "banana" flowing into
# round.json as authoritative is the failure type checking alone would pass.
test_ensure_synthesizes_an_out_of_domain_record() {
  local d; d="$(pr_test_tmpdir)"
  setup_session "$d"
  _pr_reviewer_result_write banana ok "" MINOR s m e c
  jq '.status = "banana"' < "$round_dir/.result-banana" \
    > "$round_dir/.result-banana.tmp" \
    && mv "$round_dir/.result-banana.tmp" "$round_dir/.result-banana"
  pr_reviewer_result_ensure banana; local rc=$?
  assert_exit_code "$rc" 1 "an out-of-domain status is invalid, not accepted"
  assert_contains "$(jq -r .detail < "$round_dir/.result-banana")" "record invalid" \
    "and synthesized as such"
}

test_ensure_accepts_a_valid_record_untouched() {
  local d; d="$(pr_test_tmpdir)"
  setup_session "$d"
  _pr_reviewer_result_write good ok "" MINOR s m e c
  pr_reviewer_result_ensure good
  assert_exit_code $? 0 "a valid record passes"
  assert_eq "$(jq -r .status < "$round_dir/.result-good")" ok "and is not rewritten"
}

# Loss of the store itself: ensure cannot write its synthesized record either.
test_ensure_reports_a_store_it_cannot_write() {
  pr_test_requires /dev/full || return 0
  local d; d="$(pr_test_tmpdir)"
  setup_session "$d"
  ln -s /dev/full "$round_dir/.result-gone"
  # 2>/dev/null suppresses THIS test's own provoked jq diagnostic, nothing in
  # shipped code: a green suite that prints `jq: error:` teaches its readers to
  # skim errors.
  pr_reviewer_result_ensure gone 2>/dev/null
  assert_exit_code $? 2 "an unwritable store is 2, not a synthesized 1"
}

pr_run_tests

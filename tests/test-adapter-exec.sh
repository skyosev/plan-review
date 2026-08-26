#!/usr/bin/env bash
set -uo pipefail
PR_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PR_ROOT/tests/helpers.sh"
source "$PR_ROOT/lib/adapter-exec.sh"

FAKES="$PR_ROOT/tests/fixtures/adapters"

# Every test uses the same shape: the adapter's workdir under the test's own
# tmpdir, with the four artifact paths and the log beside it.
# Bash gives an async job /dev/null as stdin unless the job redirects it
# explicitly (measured 2026-08-22, bash 5.2.21: herestring, file redirect and
# process substitution on the enclosing function all fail to arrive; a pipe
# does). The kernel's `<&0` is what makes this pass -- the staged smoke path
# shipped without it and delivered an empty prompt.
test_delivers_the_prompt_from_the_callers_stdin() {
  local d rc=99 timed_out=99; d="$(pr_test_tmpdir)"; mkdir -p "$d/w"
  pr_adapter_exec "$FAKES/fake-echo-prompt.sh" "$d/w" "" \
    "$d/review.md" "$d/meta" "$d/reason" "$d/log" 5 rc timed_out \
    <<< "the prompt itself"
  assert_exit_code "$rc" 0 "clean adapter, clean rc"
  assert_eq "$timed_out" 0 "no deadline reached"
  assert_contains "$(< "$d/review.md")" "the prompt itself" \
    "stdin reached the adapter through the kernel"
}

# D7 -- judging output over exit codes -- is caller policy. The kernel reports
# the raw code and nothing else.
test_passes_a_nonzero_exit_through_unjudged() {
  local d rc=99 timed_out=99; d="$(pr_test_tmpdir)"; mkdir -p "$d/w"
  pr_adapter_exec "$FAKES/fake-exit2-with-output.sh" "$d/w" "" \
    "$d/review.md" "$d/meta" "$d/reason" "$d/log" 5 rc timed_out \
    <<< "prompt"
  assert_exit_code "$rc" 2 "the raw code, not a ruling"
  assert_eq "$timed_out" 0 "exit 2 is not a timeout"
  assert_file_exists "$d/review.md" "the adapter's output is untouched"
}

# Trailing VAR=val words are the kernel's environment channel. An assignment
# prefixed to a *function* call is not relied on anywhere in this repo
# (tests/test-doctor.sh states why), so the kernel hands these to env(1).
test_trailing_env_words_reach_the_adapter() {
  local d rc=99 timed_out=99; d="$(pr_test_tmpdir)"; mkdir -p "$d/w"
  pr_adapter_exec "$FAKES/fake-ok.sh" "$d/w" "" \
    "$d/review.md" "$d/meta" "$d/reason" "$d/log" 5 rc timed_out \
    TMPDIR="$d/private-tmp" <<< "prompt"
  assert_contains "$(< "$d/review.md")" "tmpdir=$d/private-tmp" \
    "fake-ok reports the TMPDIR it saw"
}

# 124 = TERM deadline reached. The grandchild ignores TERM and stays in the
# group, which is the shape --kill-after cannot handle (measured 2026-08-19);
# the kernel's group sweep must dispose of it before returning, so the caller
# reads final files.
test_classifies_the_deadline_and_sweeps_the_group() {
  local d rc=99 timed_out=99; d="$(pr_test_tmpdir)"; mkdir -p "$d/w"
  PR_KILL_GRACE_SECS=1 \
    pr_adapter_exec "$FAKES/fake-term-handling-with-child.sh" "$d/w" "" \
    "$d/review.md" "$d/meta" "$d/reason" "$d/log" 1 rc timed_out \
    PR_TEST_CHILD_PIDFILE="$d/child.pid" <<< "prompt"
  assert_exit_code "$rc" 124 "TERM deadline"
  assert_eq "$timed_out" 1 "classified"
  assert_file_exists "$d/child.pid" "the fake recorded its grandchild"
  assert_pid_gone "$(< "$d/child.pid")" "grandchild survived the kernel's sweep"
}

# The sweep is unconditional: --kill-after never fires for an adapter that
# exits cleanly, so a descendant it leaked would otherwise outlive the caller.
test_sweeps_even_when_the_adapter_exits_cleanly() {
  local d rc=99 timed_out=99; d="$(pr_test_tmpdir)"; mkdir -p "$d/w"
  pr_adapter_exec "$FAKES/fake-ok-leaves-child.sh" "$d/w" "" \
    "$d/review.md" "$d/meta" "$d/reason" "$d/log" 5 rc timed_out \
    PR_TEST_CHILD_PIDFILE="$d/child.pid" <<< "prompt"
  assert_exit_code "$rc" 0 "the adapter itself succeeded"
  assert_eq "$timed_out" 0 "no deadline involved"
  assert_file_exists "$d/child.pid" "the fake recorded its child"
  assert_pid_gone "$(< "$d/child.pid")" \
    "a clean exit must not exempt the group from the sweep"
}

# The P6 gate: a grandchild that took its own session survives the group
# sweep (measured, probes 2026-08-26); the descendant sweep must reach it.
test_sweep_reaches_a_setsid_escaper() {
  pr_test_requires setsid || return 0   # util-linux command; absent on macOS
  local d; d="$(pr_test_tmpdir)"
  local rc=-1 timed_out=-1
  pr_adapter_exec "$PR_ROOT/tests/fixtures/adapters/fake-escaper.sh" "$d" "" \
    "$d/review.md" "$d/meta" "$d/reason" "$d/log" 30 rc timed_out <<< "prompt"
  assert_eq "$rc" 0 "the escaper adapter itself exits cleanly"
  assert_file_exists "$d/escaper.pid" "the fixture recorded its escaper"
  assert_pid_gone "$(< "$d/escaper.pid")" "the setsid grandchild is swept"
}

# The one parseable ps table shape the sweep fixes: two whitespace-separated
# numeric columns. GNU (coreutils 9.4) left-pads with spaces; Darwin pads wider
# and differently -- the parser must not care. Offline stand-ins for the live
# macOS check, which is owed to the macOS cycle (BACKLOG).
test_descendant_walk_parses_a_gnu_shaped_table() {
  local table=$'    100      1\n    200    100\n    201    200\n    300      1'
  assert_eq "$(_pr_ae_descendants 100 "$table")" " 100 200 201 " "fixpoint over GNU shape"
}

test_descendant_walk_parses_a_darwin_shaped_table() {
  local table=$'  100     1\n  200   100\n  201   200\n  300     1'
  assert_eq "$(_pr_ae_descendants 100 "$table")" " 100 200 201 " "fixpoint over Darwin shape"
}

pr_run_tests

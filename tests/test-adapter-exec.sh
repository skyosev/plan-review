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
    "$d/review.md" "$d/meta" "$d/reason" "$d/log" 5 "$d/tmp" rc timed_out \
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
    "$d/review.md" "$d/meta" "$d/reason" "$d/log" 5 "$d/tmp" rc timed_out \
    <<< "prompt"
  assert_exit_code "$rc" 2 "the raw code, not a ruling"
  assert_eq "$timed_out" 0 "exit 2 is not a timeout"
  assert_file_exists "$d/review.md" "the adapter's output is untouched"
}

# One fact, one channel: the kernel is the only writer of the adapter's
# deadline and TMPDIR. adapters/agy.sh derives its inner --print-timeout from
# PR_TIMEOUT_SECS, so the export is what ties agy's inner deadline to the
# round's outer one (BACKLOG 2026-08-26, /simplify).
test_kernel_exports_deadline_and_tmpdir_to_the_adapter() {
  local d; d="$(pr_test_tmpdir)"
  pr_test_mkstub "$d/env-echo.sh" \
    'cat > /dev/null; printf "secs=%s tmp=%s\n" "$PR_TIMEOUT_SECS" "$TMPDIR" > "$3"'
  local rc=-1 timed_out=-1
  pr_adapter_exec "$d/env-echo.sh" "$d" "" "$d/review.md" "$d/meta" "$d/reason" \
    "$d/log" 30 "$d/tmp" rc timed_out <<< "p"
  assert_eq "$(< "$d/review.md")" "secs=30 tmp=$d/tmp" \
    "the adapter sees the kernel's deadline and tmpdir, nothing else's"
}

# 124 = TERM deadline reached. The grandchild ignores TERM and stays in the
# group, which is the shape --kill-after cannot handle (measured 2026-08-19);
# the kernel's group sweep must dispose of it before returning, so the caller
# reads final files.
#
# This and the clean-exit case below take the fixture's DEFAULT pidfile,
# `<workdir>/child.pid`: the kernel has no PER-CALL environment channel -- its
# `env` writes PR_TIMEOUT_SECS and TMPDIR and takes no caller-supplied
# assignments -- so there is no argument to pass PR_TEST_CHILD_PIDFILE through.
# The ambient environment is of course still inherited (env(1) ADDS to it), and
# tests/test-runner.sh:147,163 and tests/test-doctor.sh:994 drive fixtures
# through exactly that; nothing here forbids it, it is just not needed. The
# default path is the one test-runner.sh already exercises the override against.
test_classifies_the_deadline_and_sweeps_the_group() {
  local d rc=99 timed_out=99; d="$(pr_test_tmpdir)"; mkdir -p "$d/w"
  PR_KILL_GRACE_SECS=1 \
    pr_adapter_exec "$FAKES/fake-term-handling-with-child.sh" "$d/w" "" \
    "$d/review.md" "$d/meta" "$d/reason" "$d/log" 1 "$d/tmp" rc timed_out \
    <<< "prompt"
  assert_exit_code "$rc" 124 "TERM deadline"
  assert_eq "$timed_out" 1 "classified"
  assert_file_exists "$d/w/child.pid" "the fake recorded its grandchild"
  assert_pid_gone "$(< "$d/w/child.pid")" "grandchild survived the kernel's sweep"
}

# The sweep is unconditional: --kill-after never fires for an adapter that
# exits cleanly, so a descendant it leaked would otherwise outlive the caller.
test_sweeps_even_when_the_adapter_exits_cleanly() {
  local d rc=99 timed_out=99; d="$(pr_test_tmpdir)"; mkdir -p "$d/w"
  pr_adapter_exec "$FAKES/fake-ok-leaves-child.sh" "$d/w" "" \
    "$d/review.md" "$d/meta" "$d/reason" "$d/log" 5 "$d/tmp" rc timed_out \
    <<< "prompt"
  assert_exit_code "$rc" 0 "the adapter itself succeeded"
  assert_eq "$timed_out" 0 "no deadline involved"
  assert_file_exists "$d/w/child.pid" "the fake recorded its child"
  assert_pid_gone "$(< "$d/w/child.pid")" \
    "a clean exit must not exempt the group from the sweep"
}

# The P6 gate: a grandchild that took its own session survives the group
# sweep (measured, probes 2026-08-26); the descendant sweep must reach it.
test_sweep_reaches_a_setsid_escaper() {
  pr_test_requires_setsid || return 0   # setsid(1) or perl; see the shim
  local d; d="$(pr_test_tmpdir)"
  local rc=-1 timed_out=-1
  pr_adapter_exec "$PR_ROOT/tests/fixtures/adapters/fake-escaper.sh" "$d" "" \
    "$d/review.md" "$d/meta" "$d/reason" "$d/log" 30 "$d/tmp" rc timed_out \
    <<< "prompt"
  assert_eq "$rc" 0 "the escaper adapter itself exits cleanly"
  assert_file_exists "$d/escaper.pid" "the fixture recorded its escaper"
  assert_pid_gone "$(< "$d/escaper.pid")" "the setsid grandchild is swept"
}

# The poll loop and post-wait sweep run ps with no deadline of their own:
# timeout(1) bounds the ADAPTER, not the loop watching it, so a ps that
# never returns (the credible trigger is a /proc read against a task in
# uninterruptible sleep -- plausible, NOT reproduced) would hang the round
# forever with the session lock held. Every ps is therefore capped; a capped
# read that dies degrades to the group-only sweep, the documented path.
test_a_hung_ps_table_read_does_not_hang_the_kernel() {
  local d rc=99 timed_out=99; d="$(pr_test_tmpdir)"; mkdir -p "$d/w" "$d/bin" "$d/tmp"
  pr_test_mkstub "$d/bin/ps" 'sleep 60'
  local t0=$SECONDS
  PATH="$d/bin:$PATH" PR_PS_CAP_SECS=1 \
    pr_adapter_exec "$FAKES/fake-echo-prompt.sh" "$d/w" "" \
    "$d/review.md" "$d/meta" "$d/reason" "$d/log" 5 "$d/tmp" rc timed_out \
    <<< "prompt"
  assert_exit_code "$rc" 0 "the adapter's own run is unaffected"
  assert_file_exists "$d/review.md" "the round still produced its artifact"
  (( SECONDS - t0 < 20 )) \
    || pr_fail "kernel took $((SECONDS - t0))s against a hung ps; the cap is not working"
}

# Same cap, the SWEEP's call site. While the adapter lives, ps is real, so
# the poller remembers the escaper's grandchild with a genuine identity.
# The fixture's exit marker then flips the stub: from the adapter's exit
# onward every ps hangs, so the post-wait sweep's identity read is the one
# that stalls -- capped, and the kernel must NOT kill a pid whose identity
# it could not re-read (unknown is not a match). The stub execs the real ps
# by absolute path so it cannot recurse into itself.
test_a_hung_sweep_identity_read_is_bounded_and_never_kills_blind() {
  pr_test_requires_setsid || return 0   # the fixture's escape needs one of the two
  local d rc=99 timed_out=99 real_ps child
  d="$(pr_test_tmpdir)"; mkdir -p "$d/w" "$d/bin" "$d/tmp"
  real_ps="$(command -v ps)"
  pr_test_mkstub "$d/bin/ps" "[[ -e \"$d/w/exiting\" ]] && sleep 60
exec $real_ps \"\$@\""
  local t0=$SECONDS
  PATH="$d/bin:$PATH" PR_PS_CAP_SECS=1 \
    pr_adapter_exec "$FAKES/fake-escaper.sh" "$d/w" "" \
    "$d/review.md" "$d/meta" "$d/reason" "$d/log" 5 "$d/tmp" rc timed_out \
    <<< "prompt"
  assert_exit_code "$rc" 0 "the adapter's own run is unaffected"
  (( SECONDS - t0 < 30 )) \
    || pr_fail "kernel took $((SECONDS - t0))s against a hung sweep read"
  # Degraded, not dangerous: the pid WAS remembered, its identity at sweep
  # time was unreadable, and the sweep must therefore have left it alone.
  child="$(< "$d/w/escaper.pid")"
  kill -0 "$child" 2>/dev/null \
    || pr_fail "the kernel killed a pid whose identity it could not re-read"
  kill -KILL "$child" 2>/dev/null   # test hygiene: reap what the kernel correctly spared
}

# The clamp, over the inputs that each break it a DIFFERENT way -- which is
# also why they need two different assertions. Measured 2026-08-27, GNU
# coreutils 9.4:
#
#   999999  accepted verbatim, so an inherited value stretches every bound to
#           days;
#   0       documented as DISABLING the timeout, and `timeout 0 sleep 3` does
#           take the full 3.003s -- the cap would be gone, not shortened,
#           which is precisely the hole this task closes;
#   abc     `timeout abc echo hi` exits 125 without running the command at
#           all.
#
# The first two are HANGS when unclamped, so elapsed time is the assertion.
# `abc` is not: unclamped it makes every ps exit 125 instantly, the table
# comes back empty on every tick, descendant tracking is silently off, and the
# round gets FASTER. A duration bound cannot fail on it -- so `abc` is checked
# where its damage actually shows, against the escaper the poller must still
# remember and the sweep must still reach.
#
# ~5s per hang value, and ~1s for the escaper: the largest single item this
# task adds to the suite, priced in CLAUDE.md's budget paragraph. It has to be
# spent, because for a clamp there is nothing observable but the consequence.
test_an_oversized_cap_is_clamped() {
  local d rc=99 timed_out=99 bad t0; d="$(pr_test_tmpdir)"
  mkdir -p "$d/w" "$d/bin" "$d/tmp"
  pr_test_mkstub "$d/bin/ps" 'sleep 60'
  for bad in 999999 0; do
    t0=$SECONDS
    PATH="$d/bin:$PATH" PR_PS_CAP_SECS="$bad" \
      pr_adapter_exec "$FAKES/fake-echo-prompt.sh" "$d/w" "" \
      "$d/review.md" "$d/meta" "$d/reason" "$d/log" 5 "$d/tmp" rc timed_out \
      <<< "prompt"
    assert_exit_code "$rc" 0 "the adapter's own run is unaffected (cap=$bad)"
    (( SECONDS - t0 < 30 )) \
      || pr_fail "kernel took $((SECONDS - t0))s; PR_PS_CAP_SECS=$bad was not clamped"
  done
}

# The other half of the clamp: a non-numeric cap must not silently switch the
# descendant sweep off. Real ps, real escaper -- if `abc` reached timeout(1),
# every ps in the poll loop would exit 125, the escaper would never be
# remembered, and it would outlive the round.
test_a_nonnumeric_cap_does_not_silently_disable_the_sweep() {
  pr_test_requires_setsid || return 0   # setsid(1) or perl; see the shim
  local d rc=-1 timed_out=-1; d="$(pr_test_tmpdir)"
  PR_PS_CAP_SECS=abc \
    pr_adapter_exec "$FAKES/fake-escaper.sh" "$d" "" \
    "$d/review.md" "$d/meta" "$d/reason" "$d/log" 30 "$d/tmp" rc timed_out \
    <<< "prompt"
  assert_eq "$rc" 0 "the escaper adapter itself exits cleanly"
  assert_pid_gone "$(< "$d/escaper.pid")" \
    "a non-numeric PR_PS_CAP_SECS turned descendant tracking off"
}

# The one parseable ps table shape the sweep fixes: two whitespace-separated
# numeric columns, which is what `ps -eo pid=,ppid=` gives on GNU and (per the
# man pages) on Darwin. The pair below differ only in COLUMN WIDTH, so what the
# second pins is that the parser does not care about padding -- it is NOT macOS
# coverage and must not be read as any: no Darwin ps produced either fixture.
# The live macOS check is still owed to the macOS cycle (BACKLOG).
test_descendant_walk_parses_a_gnu_shaped_table() {
  local table=$'    100      1\n    200    100\n    201    200\n    300      1'
  _pr_ae_descendants 100 "$table"; assert_eq "$_pr_ae_desc" " 100 200 201 " "fixpoint over GNU shape"
}

test_descendant_walk_ignores_column_width() {
  local table=$'  100     1\n  200   100\n  201   200\n  300     1'
  _pr_ae_descendants 100 "$table"; assert_eq "$_pr_ae_desc" " 100 200 201 " "fixpoint, narrower padding"
}

pr_run_tests

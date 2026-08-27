#!/usr/bin/env bash
# The execution kernel: run ONE adapter under a deadline, sweep its process
# group, report the raw facts. Two consumers on purpose -- the reviewer runner
# (lib/reviewer-runner.sh) and the doctor's smoke tier (lib/doctor.sh) -- and
# everything they disagree about stays out: D7's judge-on-output, detail
# wording, reason files, workspaces, sessions, status events, verdicts and
# retention are all caller policy. This is C4's resolution from the 2026-08-21
# dispatch-layer note: a shared core behind two thin shells, not a framework.
# pr_doctor_run stays out too -- its synchronous two-stream capture for command
# substitution is the opposite discipline, and folding it in would be the
# flag-driven single entry point that note refused.
#
# Requires timeout(1). Callers own the fallback: the smoke tier skips without
# it, the round has always assumed it.

# pr_adapter_exec <adapter> <workdir> <session> <review> <meta> <reason> <log> \
#                 <deadline-secs> <tmpdir> <rc-var> <timed-out-var>
#
# The prompt arrives on THIS function's stdin; the caller redirects it -- the
# round from a file, the smoke from a herestring -- and the kernel need not
# know. The argument order is the adapter contract's argv
# (docs/adapter-contract.md) plus log, deadline and tmpdir: the contract's
# names, not free-form strings, which is why eleven positionals do not reopen
# the transposition risk that rejected the result record's nine
# (lib/round.sh:199-204).
#
# Out, through the two namerefs: the raw exit code, and 0/1 for whether the
# deadline was reached (124 = TERM deadline; 137 = the KILL grace elapsed too).
# Execution facts only -- what they MEAN is the caller's ruling. Always
# returns 0.
#
# The kernel is the SINGLE channel for the two facts every adapter is owed:
# its deadline (docs/adapter-contract.md; adapters/agy.sh derives its inner
# --print-timeout from PR_TIMEOUT_SECS) and its private TMPDIR. Both are
# positionals here and both are exported by env(1), which still execs the
# adapter's bash in place, so it adds no process to the group and touches no
# descriptor. env is used rather than an assignment prefixed to this *function*
# call because such a prefix persists or not by shell mode -- the same reason
# tests/test-doctor.sh passes PATH as an argument.
#
# Deliberately NOT `env PR_TIMEOUT_SECS="$deadline" "$@" bash ...` with the old
# variadic VAR=val words kept alongside the export: env(1) is
# last-assignment-wins, so a caller's trailing word could silently override the
# kernel's deadline -- the exact two-channel divergence this deletes -- and
# once the deadline is exported the only remaining passenger was TMPDIR. A
# variadic mechanism for one known variable is not worth its defending
# paragraph. PR_KILL_GRACE_SECS (default 15) is read from the caller's shell:
# both callers already hold it there, and this function runs in that same
# shell, so no export is needed.
#
# `timeout` puts ITSELF in a new process group and sends TERM to that whole
# group on expiry, then SIGKILL after the grace -- but only while the direct
# child is still alive. Measured 2026-08-19: an adapter that handles TERM and
# exits is reaped at once, timeout returns 124, and a TERM-ignoring grandchild
# survives indefinitely. `bwrap --die-with-parent` does not save agy and
# claude either; without --unshare-pid it is PR_SET_PDEATHSIG on the immediate
# command, not tree cleanup. So the group is swept below, by hand, BEFORE this
# function returns -- the caller reads artifacts only after the group is dead.
#
# The sweep is UNCONDITIONAL, not post-timeout: --kill-after never fires for
# an adapter that exits cleanly, so a descendant it leaked would otherwise
# outlive the caller and could still append to artifacts already read. The
# round now publishes the REVIEW out of the survivor's reach
# (lib/reviewer-runner.sh) and that is the artifact its judgment rests on --
# but publication covers the review and only the review: <meta_out>,
# <reason_out> and the log are read in place, so for those three this sweep is
# still the only thing standing between a survivor and a file already read.
# (The smoke's core always swept this way; the round's copy
# swept only on timeout, which left exactly that gap.) Harmless when nothing
# survived: the group is already empty. The price: descendants never get the
# grace, only the direct child does -- buffered review text and vendor session
# state can be lost mid-write. Accepted: output that arrives after the adapter
# has gone cannot be attributed to the round recording it.
#
# What the group sweep does NOT do is bound a leaking reviewer. P6 (probes
# 2026-08-26) established that it reaches the spawned command of no shipped
# reviewer: agy and claude are already contained by their adapters' bwrap,
# codex by its own --as-pid-1, and `agent` by nothing at all -- its tool layer
# takes its own process group AND its own session, so a group kill on the
# timeout pid cannot address it. One real 90s round left `sleep 900` running
# after the round had returned, holding the inherited session-lock fd. So the
# group kill is followed by a DESCENDANT sweep over the pids sampled during
# the polled wait below. That sweep is best-effort by construction and is what
# bounds the leak and frees the lock; what makes the review artifact final is
# the caller's publication step (lib/reviewer-runner.sh), not either sweep.
#
# Do not reach for `setsid` here: plain `setsid cmd &` forks and the parent
# exits immediately, so `wait` returns 0 in milliseconds and the adapter is
# judged before it has written anything. `setsid -w` waits but then $! is the
# setsid parent, no longer in the child's group, so a group kill misses the
# child anyway. timeout(1) does both jobs correctly with no watchdog.

# _pr_ae_descendants <root-pid> <pid-ppid-table> -> _pr_ae_desc, space-padded
#
# Assigns rather than echoes: this runs on every poll tick of every adapter, and
# a command substitution to move one string back is a fork per tick.
#
# A ppid fixpoint over ONE ps snapshot, bash builtins over an argument table so
# the parse is testable offline against GNU- and Darwin-shaped fixtures --
# `ps -eo pid=,ppid=` is two whitespace-separated numeric columns on both, and
# the fixture test is what pins that claim. Verified live on Linux across a
# setsid boundary (probes 2026-08-26): it found every process the group sweep
# missed, structurally, with no pattern matching to confuse.
_pr_ae_descendants() {
  local p pp set_pids=" $1 " added=1
  _pr_ae_desc=''
  while (( added )); do
    added=0
    while read -r p pp; do
      [[ -z "${p:-}" ]] && continue
      case "$set_pids" in *" $p "*) continue ;; esac
      case "$set_pids" in *" $pp "*) set_pids="$set_pids$p " added=1 ;; esac
    done <<< "$2"
  done
  _pr_ae_desc="$set_pids"
}

pr_adapter_exec() {
  local adapter="$1" workdir="$2" session="$3" review="$4" meta="$5" reason="$6"
  local log="$7" deadline="$8" tmpdir="$9"
  # _pr_ae_-prefixed so a caller's own `rc`/`timed_out` can be passed without a
  # nameref self-reference; callers must not pass names starting with _pr_ae_.
  local -n _pr_ae_rc="${10}" _pr_ae_timed_out="${11}"

  # Backgrounded so $! names timeout's pid, which IS the group id. Bash gives
  # an async job /dev/null as stdin unless the job redirects it explicitly --
  # measured 2026-08-22 on bash 5.2.21: a herestring, file redirect or process
  # substitution on the enclosing function does NOT survive into the job (a
  # pipe does) -- so the `<&0` is load-bearing, not decoration: it is what
  # delivers the prompt. Nothing here closes any other descriptor, so a
  # caller-held lock fd is still inherited by the adapter and everything it
  # spawns.
  timeout --kill-after="${PR_KILL_GRACE_SECS:-15}" "$deadline" \
    env PR_TIMEOUT_SECS="$deadline" TMPDIR="$tmpdir" \
    bash "$adapter" "$workdir" "$session" "$review" "$meta" "$reason" \
    <&0 >> "$log" 2>&1 &
  local _pr_ae_pid=$!
  # The wait is POLLED, not blocking: a ppid walk only works while the tree is
  # alive, so survivors must be sampled DURING the run -- after `wait` an
  # escaper has reparented to init and no walk from this pid finds it (probes
  # 2026-08-26). Each tick unions the descendants seen so far, remembering each
  # pid with its start time. BEST-EFFORT by construction: a fork-and-detach
  # between the last sample and the kill escapes, and that window is accepted --
  # publication (lib/reviewer-runner.sh) is what makes the artifact final, not
  # this sweep; this sweep is what frees the inherited session lock and stops
  # the burn. The tick backs off 0.05 -> 0.25 -> 1s so a fast fake adapter in
  # the offline suite pays two ticks, while a real reviewer costs one ps per
  # second. Measured 2026-08-26 on this host (137 processes): 9ms for a whole
  # tick body -- ~6ms `ps -eo`, ~4ms for the fixpoint, ~6ms per `ps -o lstart=`
  # on each newly-seen pid -- plus the sleep's own fork.
  # The fixpoint makes depth+1 full passes over the whole table, so it scales
  # with processes x tree depth: on a 1000-process host with a deep reviewer
  # tree expect 100-250ms of walk per tick. Still inside the 1s tick, but it is
  # not the "~50ms" a first estimate suggested.
  # Nothing here closes a descriptor: the lock fd still rides through.
  local -A _pr_ae_seen=()
  local _pr_ae_tick=0.05 _pr_ae_table _pr_ae_p _pr_ae_id _pr_ae_desc
  # `kill -0` succeeds on a ZOMBIE, so what ends this loop is bash reaping its
  # own async job in its SIGCHLD handling and only then making the pid
  # unsignallable; `wait` below still returns the status bash stashed. Verified
  # on bash 5.2.21 -- the suite would hang otherwise -- and bash 5 is this
  # repo's floor.
  #
  # The NEW failure mode this loop introduces, absent on the blocking `wait` it
  # replaces: between that reap and the next `kill -0` the pid can be recycled,
  # and this loop would then poll an UNRELATED process until it exits -- past
  # our own deadline, after which the group kill below sweeps a stranger's
  # process group and the descendant loop kills what this poll sampled under
  # it. `wait` returned unconditionally, so on main that window was ~0; here it
  # is an unbounded hang. Same probability class as the identity risk below
  # (pid_max 4194304 here, ~99999 on macOS) and untreated for the same reason:
  # the treatment costs more than the exposure. Stated, not hidden.
  while kill -0 "$_pr_ae_pid" 2> /dev/null; do
    _pr_ae_table="$(ps -eo pid=,ppid= 2> /dev/null)" || _pr_ae_table=""
    if [[ -n "$_pr_ae_table" ]]; then
      _pr_ae_descendants "$_pr_ae_pid" "$_pr_ae_table"
      for _pr_ae_p in $_pr_ae_desc; do
        [[ "$_pr_ae_p" == "$_pr_ae_pid" ]] && continue
        [[ -n "${_pr_ae_seen[$_pr_ae_p]+x}" ]] && continue
        # A SECOND ps, so identity is NOT sampled atomically with membership:
        # if this descendant exits and its pid is recycled between the table
        # above and this call, what gets remembered is the new process's start
        # time, the check before the kill then matches trivially, and an
        # unrelated process is killed. Strictly worse than the post-sampling
        # recycle documented at the kill below -- no same-second coincidence is
        # needed, only the gap between two ps calls one iteration apart.
        # Negligible against this host's pid_max of 4194304; much less so at
        # macOS's ~99999, the platform none of this has been measured on. Not
        # folded into one atomic `ps -eo pid=,ppid=,lstart=` because that is a
        # third column shape to parse and pin across two platforms, for an
        # exposure this size.
        _pr_ae_id="$(ps -o lstart= -p "$_pr_ae_p" 2> /dev/null)"
        [[ -n "$_pr_ae_id" ]] && _pr_ae_seen[$_pr_ae_p]="$_pr_ae_id"
      done
    fi
    sleep "$_pr_ae_tick"
    case "$_pr_ae_tick" in 0.05) _pr_ae_tick=0.25 ;; 0.25) _pr_ae_tick=1 ;; esac
  done
  wait "$_pr_ae_pid"
  _pr_ae_rc=$?
  _pr_ae_timed_out=0
  [[ "$_pr_ae_rc" -eq 124 || "$_pr_ae_rc" -eq 137 ]] && _pr_ae_timed_out=1
  kill -KILL -- "-$_pr_ae_pid" 2> /dev/null
  # Identity-checked descendant kill: a remembered pid is signalled only if its
  # start time still string-equals the remembered one. lstart has ONE-SECOND
  # resolution, so this identity is probabilistic, not proof: a false kill
  # needs the pid recycled, within one round, to an unrelated process born in
  # the same wall-clock second as the sampled descendant -- at this Linux
  # host's pid_max of 4194304 that is millions of forks a second; a smaller
  # pid_max (macOS defaults far lower) narrows that margin. Accepted residual
  # risk, stated as such; never claim "never". A pid that is gone, or whose
  # identity cannot be read, is skipped -- that IS the degrade-to-group-only
  # path.
  #
  # `kill -0` FIRST, because _pr_ae_seen accumulates every distinct descendant
  # ever sampled and never shrinks, while the survivors it must actually kill
  # are a handful at most: without this line the loop spends one `ps -o lstart=`
  # fork per REMEMBERED pid, after `wait`, with the session lock held and
  # nothing printed. Measured 2026-08-27 on this host, an adapter churning ~60
  # short-lived grandchildren/second for 20s: 434 pids remembered, 2.82s of
  # post-exit sweep -- and that term is unbounded in the round's own deadline,
  # which defaults to 900s and whose prompt (lib/prompt.sh) tells reviewers to
  # run builds. Same workload with the guard: 428 pids, 0.0067s (~420x). It
  # changes no semantics -- it skips exactly the pids `kill -KILL` could not
  # have signalled anyway (ESRCH, or EPERM, which `ps` would not have helped
  # with either). Zombies still pass `kill -0` and are handled below as before.
  for _pr_ae_p in "${!_pr_ae_seen[@]}"; do
    kill -0 "$_pr_ae_p" 2> /dev/null || continue
    _pr_ae_id="$(ps -o lstart= -p "$_pr_ae_p" 2> /dev/null)"
    [[ -n "$_pr_ae_id" && "$_pr_ae_id" == "${_pr_ae_seen[$_pr_ae_p]}" ]] || continue
    kill -KILL "$_pr_ae_p" 2> /dev/null
  done
  return 0
}

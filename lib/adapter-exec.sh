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
#                 <deadline-secs> <rc-var> <timed-out-var> [VAR=val ...]
#
# The prompt arrives on THIS function's stdin; the caller redirects it -- the
# round from a file, the smoke from a herestring -- and the kernel need not
# know. The argument order is the adapter contract's argv
# (docs/adapter-contract.md) plus log and deadline: the contract's names, not
# free-form strings, which is why ten positionals do not reopen the
# transposition risk that rejected the result record's nine
# (lib/round.sh:199-204).
#
# Out, through the two namerefs: the raw exit code, and 0/1 for whether the
# deadline was reached (124 = TERM deadline; 137 = the KILL grace elapsed too).
# Execution facts only -- what they MEAN is the caller's ruling. Always
# returns 0.
#
# Trailing VAR=val words are applied to the adapter's environment via env(1),
# because an assignment prefixed to a *function* call persists or not by shell
# mode -- the same reason tests/test-doctor.sh passes PATH as an argument. env
# execs the adapter's bash in place, so it adds no process to the group and
# touches no descriptor. PR_KILL_GRACE_SECS (default 15) is read from the
# caller's shell: both callers already hold it there, and this function runs
# in that same shell, so no export is needed.
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
# outlive the caller. (The smoke's core always swept this way; the round's copy
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

# _pr_ae_descendants <root-pid> <pid-ppid-table> -> space-padded pid list
#
# A ppid fixpoint over ONE ps snapshot, bash builtins over an argument table so
# the parse is testable offline against GNU- and Darwin-shaped fixtures --
# `ps -eo pid=,ppid=` is two whitespace-separated numeric columns on both, and
# the fixture test is what pins that claim. Verified live on Linux across a
# setsid boundary (probes 2026-08-26): it found every process the group sweep
# missed, structurally, with no pattern matching to confuse.
_pr_ae_descendants() {
  local p pp set_pids=" $1 " added=1
  while (( added )); do
    added=0
    while read -r p pp; do
      [[ -z "${p:-}" ]] && continue
      case "$set_pids" in *" $p "*) continue ;; esac
      case "$set_pids" in *" $pp "*) set_pids="$set_pids$p " added=1 ;; esac
    done <<< "$2"
  done
  printf '%s' "$set_pids"
}

pr_adapter_exec() {
  local adapter="$1" workdir="$2" session="$3" review="$4" meta="$5" reason="$6"
  local log="$7" deadline="$8"
  # _pr_ae_-prefixed so a caller's own `rc`/`timed_out` can be passed without a
  # nameref self-reference; callers must not pass names starting with _pr_ae_.
  local -n _pr_ae_rc="$9" _pr_ae_timed_out="${10}"
  shift 10

  # Backgrounded so $! names timeout's pid, which IS the group id. Bash gives
  # an async job /dev/null as stdin unless the job redirects it explicitly --
  # measured 2026-08-22 on bash 5.2.21: a herestring, file redirect or process
  # substitution on the enclosing function does NOT survive into the job (a
  # pipe does) -- so the `<&0` is load-bearing, not decoration: it is what
  # delivers the prompt. Nothing here closes any other descriptor, so a
  # caller-held lock fd is still inherited by the adapter and everything it
  # spawns.
  timeout --kill-after="${PR_KILL_GRACE_SECS:-15}" "$deadline" \
    env "$@" bash "$adapter" "$workdir" "$session" "$review" "$meta" "$reason" \
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
  # the offline suite pays ~50ms, while a real reviewer costs one ps per second.
  # Nothing here closes a descriptor: the lock fd still rides through.
  local -A _pr_ae_seen=()
  local _pr_ae_tick=0.05 _pr_ae_table _pr_ae_p _pr_ae_id
  while kill -0 "$_pr_ae_pid" 2> /dev/null; do
    _pr_ae_table="$(ps -eo pid=,ppid= 2> /dev/null)" || _pr_ae_table=""
    if [[ -n "$_pr_ae_table" ]]; then
      for _pr_ae_p in $(_pr_ae_descendants "$_pr_ae_pid" "$_pr_ae_table"); do
        [[ "$_pr_ae_p" == "$_pr_ae_pid" ]] && continue
        [[ -n "${_pr_ae_seen[$_pr_ae_p]+x}" ]] && continue
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
  for _pr_ae_p in "${!_pr_ae_seen[@]}"; do
    _pr_ae_id="$(ps -o lstart= -p "$_pr_ae_p" 2> /dev/null)"
    [[ -n "$_pr_ae_id" && "$_pr_ae_id" == "${_pr_ae_seen[$_pr_ae_p]}" ]] || continue
    kill -KILL "$_pr_ae_p" 2> /dev/null
  done
  return 0
}
